# Task 46: The QUIC handshake, streams, flow control, and connection IDs

Platform: Linux.

## Goal

The QUIC connection of RFC 9000: the handshake in CRYPTO frames with the TLS state machines, streams, flow control, connection IDs, Retry and tokens, path validation, client migration, stateless reset, and idle timeout.

## Files

- `src/quic/conn.zig`, `src/quic/stream.zig`, `src/quic/frame.zig` (new).
- `src/tls/`: the QUIC transport parameters extension and the interface to the QUIC handshake.

## Test sources

- RFC 9000 and RFC 9001.

## Acceptance

```sh
CAP zig build quic-test
CAP zig build quic-fuzz -- --seconds 1800
```

Gates:

- A ztcl client and a ztcl server transfer 1 GB over loopback with 1 % loss from a test proxy.
- Each limit of the design (streams, flow control credit, connection IDs) has a test with a hostile peer.
