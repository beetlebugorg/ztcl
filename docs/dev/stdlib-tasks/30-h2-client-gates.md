# Task 30: HTTP/2 in the client, h2spec, and the HTTP/2 speed gates

Platform: shared.

## Goal

HTTP/2 in `ztcl::http client` with `-http2 auto`, interop, and the HTTP/2 speed gates.

## Files

- `src/http/client.zig`: the HTTP/2 path.
- `bench/stdlib/h2/`.

## Test sources

- `nghttpd` and a Go h2 server as peers. `h2load`.

## Acceptance

```sh
CAP tools/h2-interop.sh
CAP python3 -I tools/bench-stdlib.py --only h2 --check bench/stdlib/gates.tsv
```

Gates:

- The client passes the interop runs.
- The HTTP/2 gate of the design: at least 0.7 of Go with `h2load`.
- Size: the `h2` row of the design.
