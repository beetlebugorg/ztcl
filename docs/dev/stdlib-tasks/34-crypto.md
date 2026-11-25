# Task 34: Hashes, crypto, the capability `random`, and the tcllib names

Platform: shared.

## Goal

`ztcl::hash`, `ztcl::crypto`, the capability `random`, and the tcllib names `sha2::*`, `sha1::sha1`, `md5::md5`, `crc::crc32`, and `uuid::uuid`.

## Files

- `src/crypto/hash.zig`, `src/crypto/cmd.zig` (new).
- `src/crypto/compat.tcl` (new, embedded).

## Test sources

- NIST CAVP for SHA-1, SHA-2, and SHA-3. The BLAKE3 test vectors. RFC 4231, RFC 8032, RFC 9106, RFC 8439, RFC 5869. The tcllib test files of `sha1`, `sha256`, `md5`, `crc32`, and `uuid` (rule 9).

## Acceptance

```sh
CAP zig build crypto-vectors
CAP tools/tcllib-tests.sh sha1 sha256 md5 crc32 uuid
CAP zig-out/bin/ztcl tests/stdlib/crypto.test
```

Gates:

- Each vector passes.
- Without `random`, `ztcl::crypto random`, `uuid`, and `keypair` are absent, and a script stays deterministic.
- argon2 memory counts in the memory limit: a test with a 1 GiB cost and a 64 MiB limit stops with the memory error.
- Speed: SHA-256 and BLAKE3 at least 0.8 of `openssl speed` and of the `b3sum` program on 1 MiB inputs.
- Size: the `crypto` row of the design.
