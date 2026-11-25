# Task 12: The server: I/O threads, routes, middleware, files, streams, and shutdown

Platform: shared.

## Goal

The server API of the design, with one worker interpreter in the main thread. Task 13 adds the pool.

## Files

- `src/http/server.zig` (new): the I/O threads, keep-alive, the limits of the design, and the dispatch queue.
- `src/http/router.zig` (new): the tree of path parts and the param types.
- `src/http/server_cmd.zig` (new): `route`, `group`, `use`, `next`, `on`, `req`, `res`, `reply`, `static`, `serve`, `stop`, and `config`.
- `examples/http/` (new): the four example services of the design.
- `docs/modules/http.md` (new).

## Test sources

- RFC 9110 conditional requests and ranges (RFC 9110 sections 13 and 14).
- A path traversal list (encoded dots, backslashes, NUL bytes, overlong UTF-8) for `reply file`.

## Acceptance

```sh
CAP zig-out/bin/ztcl tests/stdlib/http-server.test
CAP tools/http-examples.sh      # starts each example and runs its curl checks
CAP timeout 120 tools/http-shutdown.sh   # SIGTERM with requests in flight
```

Gates:

- Each traversal case gives 404.
- A graceful stop ends each request in flight that ends within the grace time, and closes the rest.
- A route lookup in a table of 10 000 routes costs at most 2 times a lookup in a table of 10, as an instruction count.
