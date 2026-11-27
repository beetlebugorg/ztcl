#!/bin/sh
# Runs the ztcl TLS client against `openssl s_server` on 127.0.0.1.
#
#   tools/tls-interop.sh [--quick] client
#
# The script makes a CA and a leaf for each key kind (P-256, P-384,
# Ed25519, RSA 2048) with `openssl`, in a temporary folder. The client
# must connect for each key kind, each suite, and each group, with ALPN,
# and with a HelloRetryRequest. It must refuse a wrong host name, a leaf
# of an unknown CA, and an expired leaf. --quick runs each suite and each
# group with the P-256 key only, and each key kind with the default
# suite and group.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
quick=0
if [ "${1:-}" = --quick ]; then quick=1; shift; fi
[ "${1:-}" = client ] || { echo "usage: tools/tls-interop.sh [--quick] client" >&2; exit 2; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig build tls-interop >/dev/null
bin=$root/zig-out/bin/tls-interop
tmp=$(mktemp -d)
pid=
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -r "$tmp"
}
trap cleanup EXIT
cd "$tmp"
printf '[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n' > ca.cnf
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost.test\n' > leaf.ext
printf '[req]\ndistinguished_name=d\n[d]\n' >> ca.cnf
key() {
    case $1 in
        p256) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$2" ;;
        p384) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$2" ;;
        ed25519) openssl genpkey -algorithm ED25519 -out "$2" ;;
        rsa) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$2" ;;
    esac 2>/dev/null
}
key p256 ca.key
openssl req -x509 -new -key ca.key -subj /CN=interop-ca -days 30 -extensions v3 -config ca.cnf -out ca.pem 2>/dev/null
key p256 other.key
openssl req -x509 -new -key other.key -subj /CN=other-ca -days 30 -extensions v3 -config ca.cnf -out other.pem 2>/dev/null
for k in p256 p384 ed25519 rsa; do
    key $k $k.key
    openssl req -new -key $k.key -subj /CN=localhost.test -config ca.cnf -out $k.csr 2>/dev/null
    openssl x509 -req -in $k.csr -CA ca.pem -CAkey ca.key -days 30 -extfile leaf.ext -out $k.pem 2>/dev/null
done
# -not_before and -not_after are in OpenSSL 3.4 and later.
expired=1
openssl x509 -req -in p256.csr -CA ca.pem -CAkey ca.key -not_before 20200101000000Z -not_after 20210101000000Z -extfile leaf.ext -out expired.pem 2>/dev/null || expired=0

port=$((20000 + $$ % 20000))
pass=0
fail=0
# serve CERT KEY [s_server options]
serve() {
    cert=$1 keyf=$2
    shift 2
    [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    port=$((port + 1))
    openssl s_server -tls1_3 -www -accept "$port" -cert "$cert" -key "$keyf" "$@" </dev/null >server.log 2>&1 &
    pid=$!
    i=0
    while ! grep -q ACCEPT server.log; do
        i=$((i + 1)); [ $i -gt 50 ] && { echo "s_server did not start"; cat server.log; exit 1; }
        sleep 0.1
    done
}
# expect ok|fail NAME [client options]
expect() {
    want=$1 name=$2 ca=$3 host=$4
    shift 4
    if out=$("$bin" "$port" "$ca" "$host" "$@" 2>&1); then got=ok; else got=fail; fi
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1)); echo "pass $name: $out"
    else
        fail=$((fail + 1)); echo "FAIL $name: want $want, got: $out"
    fi
}
for k in p256 p384 ed25519 rsa; do
    serve $k.pem $k.key
    expect ok "key $k" ca.pem localhost.test
done
serve p256.pem p256.key -ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256 -groups X25519:P-256:P-384
for s in aes_128_gcm_sha256 aes_256_gcm_sha384 chacha20_poly1305_sha256; do
    expect ok "suite $s" ca.pem localhost.test --suite $s
done
for g in x25519 secp256r1 secp384r1; do
    expect ok "group $g" ca.pem localhost.test --group $g
done
serve p256.pem p256.key -alpn h2,http/1.1
expect ok "alpn" ca.pem localhost.test --alpn h2
# The client sends an X25519 share, and the server asks for P-384.
serve p256.pem p256.key -groups P-384
expect ok "HelloRetryRequest" ca.pem localhost.test
serve p256.pem p256.key
expect fail "wrong host" ca.pem other.test
expect fail "unknown CA" other.pem localhost.test
if [ $expired = 1 ]; then
    serve expired.pem p256.key
    expect fail "expired leaf" ca.pem localhost.test
else
    echo "skip expired leaf: this openssl has no -not_before"
fi
if [ $quick = 0 ]; then
    for k in p384 ed25519 rsa; do
        serve $k.pem $k.key -ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        for s in aes_128_gcm_sha256 aes_256_gcm_sha384 chacha20_poly1305_sha256; do
            for g in x25519 secp256r1 secp384r1; do
                expect ok "key $k suite $s group $g" ca.pem localhost.test --suite $s --group $g
            done
        done
    done
fi
echo "$pass pass, $fail fail"
[ $fail = 0 ]
