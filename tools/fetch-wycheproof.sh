#!/bin/sh
# Downloads the Wycheproof test sets of the TLS primitives and checks the
# SHA-256 of each file. Prints the folder.
#
#   tools/fetch-wycheproof.sh [DIR]      (the default is zig-out/wycheproof)
#   zig build tls-wycheproof -- "$(tools/fetch-wycheproof.sh)"
#
# The files are from a fixed commit of github.com/C2SP/wycheproof
# (Apache-2.0). The repository has no copy of them.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir=${1:-$here/../zig-out/wycheproof}
mkdir -p "$dir" || exit 1
dir=$(CDPATH= cd -- "$dir" && pwd)
src=https://raw.githubusercontent.com/C2SP/wycheproof/65ca494727a52944c204441c860b039e6786b99b/testvectors_v1
while read -r name sum; do
    f=$dir/$name
    if [ -f "$f" ] && echo "$sum  $f" | sha256sum -c --status 2>/dev/null; then continue; fi
    curl -sSfL --retry 3 -o "$f.part" "$src/$name" || { echo "cannot fetch $name" >&2; exit 1; }
    if ! echo "$sum  $f.part" | sha256sum -c --status; then
        echo "the SHA-256 of $name does not match" >&2; rm -f "$f.part"; exit 1
    fi
    mv "$f.part" "$f"
done <<EOT
aes_gcm_test.json 985e5ecc172e181eaf49e89508b9470dcf478002eb7e8559c707eb42dc97dfe7
chacha20_poly1305_test.json fe61d25f90e1bde4461d00eafe61049e5f29bd999f36b766df9cda90906ad53d
ecdh_secp256r1_ecpoint_test.json 648f16d077caf2400d02331ca51f44744c72c799830c8d0595d0b18b6dd9f886
ecdh_secp384r1_ecpoint_test.json ffa7835fe1de359dff762c8f1272b98acebd5578e2f855d969051ff956c6dca3
ecdsa_secp256r1_sha256_test.json 182db4f3e230f6f9fa9f800d2a614dede30284b8e8438bbfe1171905402e9332
ecdsa_secp384r1_sha384_test.json 8a5b3ae1760975143414811f13588c24d951d9d8c904195087ba327591dfe9cc
ed25519_test.json ea80ffebac085e21cb9d3e903e7fa2b448d96702da5b31f061d0b83b430b74b3
hkdf_sha256_test.json bb2b462a38b251cb52a2aede706d6d4b62b26864f4e80c95497507ddb07c5f1e
hkdf_sha384_test.json 69ff6ea3657bb9c1b8cdffbbb4e7832353d08fd15c0d9997b03f7a6b180e3678
hmac_sha256_test.json 2d201cfa61d1bf95e6f5d07d96634b4a348b31e8eaa277ad7c8d09677b7a743f
hmac_sha384_test.json 28b9776e979dd755d852ca471043ea6cedce8b15f7a28abdf6ea9efd982b43c0
rsa_pss_2048_sha256_mgf1_32_test.json 7f6efafc160f4816b96cbf1c12188a31051d7e3f001e27505d9edb5f2a0e325c
rsa_pss_2048_sha384_mgf1_48_test.json 66d464778b0b2f683a1d1a20e94f77e9472b8cc393b45f423fa08a48e677063c
rsa_pss_3072_sha256_mgf1_32_test.json cca48433e6d1accb57f65b3396c4f4dd93c776467101c3f0948e74c283fd4749
rsa_pss_4096_sha512_mgf1_64_test.json c93ceaa56a190c9fd4707441c5c6a75839f108202d88aec891697f9623042547
rsa_signature_2048_sha256_test.json 94a917b01ff50fb874cfc05bf29b4af44868d944a6558201cf18380da93fb393
rsa_signature_2048_sha384_test.json c571c105d261c0ff588a2888a529f152563fb3b77894b7620d4e4f8f934f2c1d
rsa_signature_3072_sha256_test.json 0f5f18cabfaad3e2792e82f7e9882f8999049b456714de924b8a5e202f61ca43
rsa_signature_4096_sha512_test.json 9d6e67b1eb0d7040db411835238efd20e9302399a258bdff82de3f38e0f2855a
x25519_test.json 35c3f5231cf25cc640b524d403461deee9e49441d5d915a3a25b2c8ff5adbe7d
EOT
echo "$dir"
