# Task 24: RSA-PSS server keys

Platform: shared.

## Goal

RSA private keys for a server: PKCS#1 and PKCS#8 parse, and RSA-PSS sign with blinding on `std.crypto.ff`.

## Files

- `src/tls/rsa.zig` (new).

## Test sources

- The Wycheproof RSA-PSS sets. RFC 8017. RFC 8446 section 4.2.3.

## Acceptance

```sh
CAP zig build tls-vectors
CAP tools/tls-interop.sh --keys rsa
CAP zig build tls-timing -- --only rsa
```

Gates:

- Each signature verifies with `openssl` and with `std.crypto.Certificate.rsa`.
- The timing test of task 23 passes for the sign with two keys and many messages.

Decision 6 of the user decides if this task is in milestone 4 or later.
