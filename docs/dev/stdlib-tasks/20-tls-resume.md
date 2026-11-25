# Task 20: Resumption, tickets, 0-RTT off by default, and key update

Platform: shared.

## Goal

PSK resumption with `psk_dhe_ke`, sealed tickets with a key that rotates, the anti-replay window, 0-RTT behind an option, and key update on a byte or record count.

## Files

- `src/tls/ticket.zig` (new).
- `src/tls/server.zig`, `src/tls/client.zig`: the PSK paths.

## Test sources

- RFC 8448 resumed 0-RTT trace. RFC 8446 sections 2.2, 2.3, 4.6, and 8.

## Acceptance

```sh
CAP zig build tls-vectors
CAP tools/tls-interop.sh --quick resume
```

Gates:

- With 0-RTT off, early data is refused, and the handshake goes on as 1-RTT.
- With 0-RTT on, a replayed ClientHello with early data inside the window is refused.
- A ticket from before a key rotation of two periods is refused.
