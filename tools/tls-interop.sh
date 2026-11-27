#!/bin/sh
# Runs the ztcl TLS client against `openssl s_server` on 127.0.0.1.
#
#   tools/tls-interop.sh [--quick] client
#   tools/tls-interop.sh socket
#   tools/tls-interop.sh [--quick] server
#
# The script makes a CA and a leaf for each key kind (P-256, P-384,
# Ed25519, RSA 2048) with `openssl`, in a temporary folder. The client
# must connect for each key kind, each suite, and each group, with ALPN,
# and with a HelloRetryRequest. It must refuse a wrong host name, a leaf
# of an unknown CA, and an expired leaf. --quick runs each suite and each
# group with the P-256 key only, and each key kind with the default
# suite and group. `socket` runs the same server checks with the
# `ztcl::tls socket` command of zig-out/bin/ztcl. `server` runs the
# server of tls-interop with each key kind but RSA (task 24), and
# connects with `openssl s_client` and `curl` for each suite, each
# group, ALPN, and a HelloRetryRequest. A TLS 1.2 client must fail.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
quick=0
if [ "${1:-}" = --quick ]; then quick=1; shift; fi
mode=${1:-}
case $mode in client|socket|server) ;; *) echo "usage: tools/tls-interop.sh [--quick] client|socket|server" >&2; exit 2 ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$mode" != socket ]; then
    zig build tls-interop >/dev/null
    bin=$root/zig-out/bin/tls-interop
else
    zig build >/dev/null
    ztcl=$root/zig-out/bin/ztcl
fi
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
if [ "$mode" = server ]; then
    # ours KEY [server options]: the server of tls-interop on a new port.
    ours() {
        k=$1
        shift
        [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
        port=$((port + 1))
        cat $k.pem $k.key > srv.pem
        "$bin" server "$port" srv.pem "$@" >server.log 2>&1 &
        pid=$!
        i=0
        while ! grep -q listening server.log; do
            i=$((i + 1)); [ $i -gt 50 ] && { echo "tls-interop server did not start"; cat server.log; exit 1; }
            sleep 0.1
        done
    }
    # check ok|fail NAME WANT COMMAND...: the output of the command must
    # have WANT for ok, and must not for fail.
    check() {
        want=$1 name=$2 text=$3
        shift 3
        out=$(printf 'GET / HTTP/1.0\r\n\r\n' | "$@" 2>&1 || true)
        if printf '%s' "$out" | grep -q -- "$text"; then got=ok; else got=fail; fi
        if [ "$got" = "$want" ]; then
            pass=$((pass + 1)); echo "pass $name"
        else
            fail=$((fail + 1)); echo "FAIL $name: want $want, got: $(printf '%s' "$out" | tail -n 3)"
        fi
    }
    sc() { timeout 10 openssl s_client -tls1_3 -connect "127.0.0.1:$port" -servername localhost.test -CAfile ca.pem -verify_return_error -quiet "$@"; }
    cu() { timeout 10 curl -s --tlsv1.3 --cacert ca.pem --resolve "localhost.test:$port:127.0.0.1" "$@" "https://localhost.test:$port/"; }
    for k in p256 p384 ed25519; do
        ours $k
        check ok "s_client key $k" "sni=localhost.test" sc
        check ok "curl key $k" "sni=localhost.test" cu
        if [ $quick = 1 ] && [ $k != p256 ]; then continue; fi
        for s in TLS_AES_128_GCM_SHA256:aes_128_gcm_sha256 TLS_AES_256_GCM_SHA384:aes_256_gcm_sha384 TLS_CHACHA20_POLY1305_SHA256:chacha20_poly1305_sha256; do
            check ok "s_client key $k suite ${s%%:*}" "suite=${s##*:}" sc -ciphersuites "${s%%:*}"
        done
        for g in X25519 P-256 P-384; do
            check ok "s_client key $k group $g" "sni=localhost.test" sc -groups "$g"
        done
    done
    ours p256 --alpn h2
    check ok "s_client alpn" "alpn=h2" sc -alpn h2,http/1.1
    # curl offers h2 and http/1.1, and speaks HTTP/2 after h2.
    ours p256 --alpn http/1.1
    check ok "curl alpn" "alpn=http/1.1" cu
    # openssl sends an X25519 share only, and the server has P-384 only.
    ours p256 --group secp384r1
    check ok "s_client HelloRetryRequest" "sni=localhost.test" sc -groups X25519:P-384
    check ok "curl HelloRetryRequest" "sni=localhost.test" cu --curves X25519:P-384
    check fail "TLS 1.2 client" "sni=localhost.test" timeout 10 curl -s --tls-max 1.2 --cacert ca.pem --resolve "localhost.test:$port:127.0.0.1" "https://localhost.test:$port/"
    grep -q protocol_version server.log && { pass=$((pass + 1)); echo "pass TLS 1.2 client gets protocol_version"; } || { fail=$((fail + 1)); echo "FAIL TLS 1.2 client: no protocol_version alert"; }
    echo "$pass pass, $fail fail"
    [ $fail = 0 ]
    exit
fi
if [ "$mode" = socket ]; then
    # tcl NAME WANT SCRIPT: the script gets $port and $ca, and its last
    # line of output must be WANT.
    tcl() {
        printf 'package require ztcl::tls\nset port %s\nset f [open ca.pem]\nset ca [read $f]\nclose $f\n%s\n' "$port" "$3" > case.tcl
        out=$("$ztcl" --allow socket,channels,file case.tcl 2>&1 | tail -n 1)
        if [ "$out" = "$2" ]; then
            pass=$((pass + 1)); echo "pass $1: $out"
        else
            fail=$((fail + 1)); echo "FAIL $1: want $2, got: $out"
        fi
    }
    get='set s [ztcl::tls socket -servername localhost.test -cadata $ca 127.0.0.1 $port]
puts -nonewline $s "GET / HTTP/1.0\r\n\r\n"
flush $s
set line [gets $s]
read $s
close $s
puts $line'
    for k in p256 p384 ed25519 rsa; do
        serve $k.pem $k.key
        tcl "key $k" "HTTP/1.0 200 ok" "$get"
    done
    serve p256.pem p256.key -alpn h2,http/1.1
    tcl "alpn" "HTTP/1.0 200 ok" "$(printf '%s' "$get" | sed 's/-cadata/-alpn {h2 http\/1.1} -cadata/')"
    tcl "wrong host" "ZTCL TLS CERTIFICATE HostName" 'catch {ztcl::tls socket -servername other.test -cadata $ca 127.0.0.1 $port} m o; puts [dict get $o -errorcode]'
    tcl "unknown CA" "ZTCL TLS CERTIFICATE UnknownIssuer" 'set f [open other.pem]; set o2 [read $f]; close $f; catch {ztcl::tls socket -servername localhost.test -cadata $o2 127.0.0.1 $port} m o; puts [dict get $o -errorcode]'
    tcl "no verify" "HTTP/1.0 200 ok" "$(printf '%s' "$get" | sed 's/-cadata \$ca/-verify 0/')"
    tcl "large write" "HTTP/1.0 200 ok" "$(printf '%s' "$get" | sed 's/GET \/ HTTP\/1.0\\r\\n/GET \/ HTTP\/1.0\\r\\nX: [string repeat a 40000]\\r\\n/')"
    if [ $expired = 1 ]; then
        serve expired.pem p256.key
        tcl "expired leaf" "ZTCL TLS CERTIFICATE Expired" 'catch {ztcl::tls socket -servername localhost.test -cadata $ca 127.0.0.1 $port} m o; puts [dict get $o -errorcode]'
    fi
    echo "$pass pass, $fail fail"
    [ $fail = 0 ]
    exit
fi
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
