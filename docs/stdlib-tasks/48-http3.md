# Task 48: HTTP/3 and QPACK

Platform: Linux.

## Goal

HTTP/3 of RFC 9114 and QPACK of RFC 9204 in the server and the client, with `Alt-Svc` on the TCP server.

## Files

- `src/h3/` (new): frames, the control streams, QPACK with its encoder and decoder streams.
- `src/http/server.zig` and `src/http/client.zig`: the HTTP/3 path.

## Test sources

- RFC 9114 and RFC 9204. The QPACK interop corpus (`qifs`).

## Acceptance

```sh
CAP zig build qpack-test -- path/to/qifs
CAP zig build h3-test
```

Gates:

- Each file of the corpus decodes and encodes against each other stack of the corpus.
- The handlers of `examples/http/` work over HTTP/3 with no change.
