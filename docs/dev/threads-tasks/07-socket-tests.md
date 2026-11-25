# Task 07: the thread tests of `socket.test` and `unixNotfy.test`

Platform: Linux.

## Goal

The 10 tests with the constraint `thread` in `socket.test` and the 2 in `unixNotfy.test`.

## Files

- The files of the cause of each failure. Expect `src/event.zig` and `src/thread.zig`.

## Rules

1. A thread that waits for a socket and a message polls in slices of 10 ms.
2. Report each test that cannot pass, with its cause.

## Acceptance

```sh
CAP tools/suite.sh socket.test unixNotfy.test
```

The pass count of `socket.test` is at least 147 plus each thread test that passes.
