# Task 06: `aio` on io_uring and epoll

Platform: Linux.

## Goal

The `aio` layer: an implementation of the `std.Io` vtable subset that ztcl needs, on Linux.

## Files

- `src/aio/` (new): `aio.zig` (the interface and the loop of one thread), `uring.zig`, `epoll.zig`, and `tests.zig`.
- `docs/stdlib.md`: the result of the test of `std.Io.Uring` (which parts ztcl uses, and which parts it implements).

## Rules

1. The step limit and the memory limit do not apply here: `aio` has no interpreter. Each buffer has a fixed top, and the tests check it.

## Test sources

- The operations of the design: accept, connect, read, write, `sendfile`, timers, cancel, a wake from another thread, and a wait with a deadline.

## Acceptance

```sh
CAP zig build test
CAP zig build aio-test
CAP zig build aio-test -Daio=epoll
CAP timeout 600 zig build aio-stress -- --conns 10000 --seconds 300
```

Gates:

- Both backends pass the same tests.
- The stress run: 10 000 loopback connections, no leaked descriptor, and a flat memory size after the first minute.
- A process with io_uring off by seccomp uses epoll and passes the tests.
- Size: the `aio` row of the design.
