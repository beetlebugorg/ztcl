# Task 14: WebSockets and SSE

Platform: shared.

## Goal

The `websocket` route, `reply sse`, the WebSocket client, and the tcllib `websocket` client names.

## Files

- `src/http/ws.zig` (new): RFC 6455 frames, fragments, masks, ping and pong, close codes, and the limits. It reuses the handshake check of `std.http.Server.Request.upgradeRequested`.
- `src/http/sse.zig` (new).

## Test sources

- The Autobahn test suite (`wstest` fuzzing client against the server, fuzzing server against the client), cases 1 to 10, with compression cases 12 and 13 excluded until permessage-deflate is in.
- The SSE parse rules of the HTML standard.

## Acceptance

```sh
CAP tools/autobahn.sh server
CAP tools/autobahn.sh client
CAP zig-out/bin/ztcl tests/stdlib/sse.test
```

Gates:

- Autobahn: each case is OK or NON-STRICT, and each NON-STRICT case has a cause in the PR.
- 10 000 WebSocket connections on one worker with `-concurrency 10000` hold a flat memory size.
