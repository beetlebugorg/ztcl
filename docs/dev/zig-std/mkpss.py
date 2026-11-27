# Makes the PSS signature of pss_padding.zig: EMSA-PSS-ENCODE of RFC 8017
# with one non-zero byte in PS, signed with the private key in PEM file
# argv[1] (openssl genrsa 2048). Run with python3 -I mkpss.py key.pem.
#
# SPDX-License-Identifier: BSD-2-Clause
import hashlib, re, subprocess, sys
t = subprocess.run(["openssl","rsa","-in",sys.argv[1],"-noout","-text"],capture_output=True,text=True).stdout
def field(name):
    m = re.search(name + r":\s*\n((?:\s+[0-9a-f:]+\n)+)", t)
    return int(re.sub(r"[\s:]", "", m.group(1)), 16)
n = field("modulus"); d = field("privateExponent"); e = 65537
k = 256; emLen = 256; h = hashlib.sha256
msg = b"zig std pss"
mhash = h(msg).digest(); salt = bytes(range(32))
H = h(b"\0"*8 + mhash + salt).digest()
ps = bytearray(emLen - 32 - 32 - 2)
ps[10] = 0x5a   # a non-zero byte inside the zero padding PS
db = bytes(ps) + b"\x01" + salt
def mgf1(seed, l):
    out = b""; c = 0
    while len(out) < l:
        out += h(seed + c.to_bytes(4,"big")).digest(); c += 1
    return out[:l]
masked = bytearray(a ^ b for a, b in zip(db, mgf1(H, len(db))))
masked[0] &= 0x7f
em = bytes(masked) + H + b"\xbc"
sig = pow(int.from_bytes(em,"big"), d, n)
print("const n_hex = \"%s\";" % n.to_bytes(k,"big").hex())
print("const sig_hex = \"%s\";" % sig.to_bytes(k,"big").hex())
