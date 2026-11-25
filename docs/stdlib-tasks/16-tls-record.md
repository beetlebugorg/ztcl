# Task 16: The TLS record layer and the key schedule

Platform: shared.

## Goal

The record layer and the key schedule of TLS 1.3, shared by both sides.

## Files

- `src/tls/record.zig` (new): framing, seal and open, sequence numbers, padding, the record limits of RFC 8446 section 5, and key update.
- `src/tls/schedule.zig` (new): the key schedule of RFC 8446 section 7 on `std.crypto.kdf.hkdf`.
- `docs/tls.md` (new): the threat model and the rules of this milestone.

## Test sources

- RFC 8448: each secret, key, IV, and record of each trace (the simple 1-RTT handshake, resumed 0-RTT, HelloRetryRequest, client authentication, and the compatibility mode).
- RFC 5869 (HKDF), RFC 8439, and the Wycheproof sets of AES-GCM and ChaCha20-Poly1305.

## Acceptance

```sh
CAP zig build test
CAP zig build tls-vectors
```

Gates:

- Each value of RFC 8448 matches byte for byte.
- A record with a bad tag, a bad length, or a content type of zero gives the alert of the RFC.
- The open of a record compares the tag with `std.crypto.timing_safe` and scans the padding to the start of the record.
