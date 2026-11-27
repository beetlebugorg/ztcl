# Zig std findings

The TLS work of ztcl#27 found two problems in `std.crypto.Certificate` of Zig 0.17.0. ztcl has its own code for both, so ztcl does not depend on a fix. This page has the facts and a minimal reproducer for each problem. The ztcl project has not reported them upstream.

The reproducers are in [zig-std/](zig-std/). Run them with Zig 0.17.0:

```sh
zig test docs/dev/zig-std/pss_padding.zig
zig test docs/dev/zig-std/der_panic.zig --test-filter "reads past"
```

## 1. The RSA-PSS check reads one byte of the padding

`rsa.PSSSignature.verify` runs EMSA-PSS-VERIFY of RFC 8017 section 9.1.2. Step 10 says: if the `emLen - hLen - sLen - 2` leftmost octets of DB are not zero, the result is "inconsistent". The code in `Certificate.zig` (function `EMSA_PSS_VERIFY`) checks only the last of these octets, `dbMask[mgf_len - sLen - 2]`. A non-zero byte at a lower index of PS gives no error.

`pss_padding.zig` has a 2048-bit RSA key (e = 65537) and a signature of the message `zig std pss` with SHA-256, MGF1-SHA-256, and a salt of 32 bytes. Byte 10 of PS is 0x5a. All other parts of the encoding are correct. `mkpss.py` made the key and the signature.

- `rsa.PSSSignature.verify` returns with no error. The test passes.
- `openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 -verify` (OpenSSL 3.6.5) gives "Verification failure" for the same signature. With PS all zero, it gives "Verified OK".
- The Wycheproof RSA-PSS sets have cases of this type. ztcl ran them in #384 and found signatures that the std check accepts.

The hash `H` does not cover PS. The bad bytes change the signature value, and the signed message stays the same. A signature of this form needs the private key. This page does not test a forgery without the key.

`std.crypto.tls.Client` uses `rsa.PSSSignature` for the `rsa_pss_rsae_*` and `rsa_pss_pss_*` schemes of CertificateVerify (`tls/Client.zig`, function `SchemeRsa`).

A fix is to check each octet of `dbMask[0 .. mgf_len - sLen - 1]` for zero. ztcl has its own check in `pssCheck` of `src/tls/crypto.zig`, and a test there uses the same key and signatures.

## 2. The DER reader has no bounds checks

`der.Element.parse(bytes, index)` reads `bytes[i]` for the tag, the length byte, and each byte of a long-form length, with no check against `bytes.len`. It also computes `end = i + long_form_size` in a `u32` with no overflow check, and it does not check that `end` is inside `bytes`. Each caller then slices or reads at these indices.

`der_panic.zig` has three tests. Each one panics in a Debug build:

| Test | Input | Panic |
|---|---|---|
| `reads past` | `Element.parse(&.{0x30}, 0)` | index out of bounds: index 1, len 1 (the length byte) |
| `SEQUENCE whose` | `Certificate.parse` of the 2 bytes `30 7f` | index out of bounds: index 2, len 2 (the tag of the TBSCertificate) |
| `overflows` | `Element.parse(&.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff }, 0)` | integer overflow in `i + long_form_size` |

Run one test at a time with `--test-filter`, because the first panic stops the test runner. In a ReleaseFast or ReleaseSmall build these reads are undefined behavior.

The return type of `Certificate.parse` has `ParseError` for bad bytes, but these bytes give a panic. `std.crypto.tls.Client` calls `parse` on each certificate from the server (`tls/Client.zig`, the Certificate message). This page does not test that path with a TLS server.

A fix is to check `i < bytes.len` before each read, and to check `end <= bytes.len` with an overflow check before the return. ztcl reads DER with `src/tls/der.zig`, which has these checks, and runs a fuzz test on it (`src/tls/x509_fuzz.zig`).
