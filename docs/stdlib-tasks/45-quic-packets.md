# Task 45: UDP on `aio`, QUIC packets, and packet protection

Platform: Linux.

## Goal

UDP with `recvmmsg`, `sendmmsg`, and GSO on `aio`. The QUIC packet formats, header protection, and packet protection on the AEAD and key schedule of TLS.

## Files

- `src/aio/udp.zig` (new).
- `src/quic/packet.zig`, `src/quic/protect.zig` (new).

## Test sources

- RFC 9000 section 17. RFC 9001 appendix A (the Initial packets, the server Initial, the Retry, and the ChaCha20 short header).

## Acceptance

```sh
CAP zig build quic-vectors
CAP zig build quic-packet-fuzz -- --seconds 600
```

Gates:

- Each value of RFC 9001 appendix A matches byte for byte.
