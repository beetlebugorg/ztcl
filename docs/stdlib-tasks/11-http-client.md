# Task 11: The HTTP/1.1 parser, the client, and the `http` package names

Platform: shared.

## Goal

An HTTP/1.1 parser for both sides, and the client of the design with the names of the core `http` package.

## Files

- `src/http/parse.zig` (new): the request and response heads, chunked bodies, and the limits. It reuses `std.http.HeadParser` and `std.http.ChunkParser` where they pass the tests.
- `src/http/client.zig` (new): pools, redirects, timeouts, and the network policy for each address.
- `src/http/cmd.zig` (new): `zt::http get|post|request|client`.
- `src/http/compat.tcl` (new, embedded): `http::geturl` and the other names of the design.

## Test sources

- RFC 9110 and RFC 9112. The request smuggling cases of RFC 9112 section 11 (two `Content-Length` headers, `Transfer-Encoding` with `Content-Length`, bad chunk sizes, bare CR).
- The core file `http.test` of Tcl 8.6.16 (it runs `httpd` of the test folder with `exec` and loopback).

## Acceptance

```sh
CAP tools/suite.sh http.test
CAP zig-out/bin/ztcl tests/stdlib/http-client.test
CAP zig build http-parse-fuzz -- --seconds 600
```

Gates:

- Each smuggling case is refused.
- `http.test` passes at least the count that the PR reports as the baseline, and each failure has a cause.
- Size: part of the `http` row of the design.
