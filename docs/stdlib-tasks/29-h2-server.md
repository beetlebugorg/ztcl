# Task 29: HTTP/2 in the server: frames, streams, flow control, and limits

Platform: shared.

## Goal

HTTP/2 of RFC 9113 in the server, with `h2` over TLS by ALPN and `h2c` with prior knowledge, and the limits against the known attacks.

## Files

- `src/h2/frame.zig`, `src/h2/conn.zig`, and `src/h2/stream.zig` (new).
- `src/http/server.zig`: the HTTP/2 path. A handler sees the same `req` and `res`.

## Test sources

- RFC 9113 and RFC 9218. h2spec. The attack cases of the design (rapid reset, CONTINUATION flood, settings flood, ping flood, zero window, HPACK bomb).

## Acceptance

```sh
CAP tools/h2spec.sh            # h2spec against h2c and h2
CAP zig build h2-attack-test
CAP zig build h2-fuzz -- --seconds 600
```

Gates:

- h2spec passes each test.
- Each attack case closes the connection with the error code of the design and keeps the memory of the server flat.
