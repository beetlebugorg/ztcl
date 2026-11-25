# Task 07: The event loop, channels, and sockets on `aio`, and calls that yield

Platform: Linux.

## Goal

`src/event.zig` waits on `aio`. A blocking call of a module yields in a coroutine, and runs the loop outside one.

## Files

- `src/event.zig`: the wait. The hunk of the wait only.
- `src/sock.zig`, `src/chan.zig`: sockets and channels on `aio`. The policy checks stay in place.
- `src/aio/yield.zig` (new): the helper that a module command calls to start an operation and yield or wait.

## Test sources

- The core files `event.test`, `socket.test`, `timer.test`, `ioCmd.test`, `chanio.test`, and `coroutine.test`.

## Acceptance

```sh
CAP tools/suite.sh event.test socket.test timer.test ioCmd.test chanio.test coroutine.test
CAP tools/suite.sh -a
CAP zig-out/bin/ztcl tests/stdlib/yield.test
```

Gates:

- The pass count of each file must not drop.
- A test with 1000 coroutines that each sleep and read a socket shows the order of the resumes and a flat memory size.
