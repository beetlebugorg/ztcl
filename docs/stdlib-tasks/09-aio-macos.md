# Task 09: `aio` on kqueue

Platform: macOS.

## Goal

The `aio` layer on macOS. Compare `std.Io.Dispatch` and `std.Io.Kqueue` against the tests of task 06, pick one, and implement the missing parts on kqueue.

## Files

- `src/aio/kqueue.zig` (new).
- `docs/stdlib.md`: the result of the comparison.

## Test sources

- The tests of task 06.

## Acceptance

```sh
CAP zig build aio-test
CAP timeout 600 zig build aio-stress -- --conns 5000 --seconds 300
CAP tools/suite.sh event.test socket.test timer.test
```

Gates:

- The tests of task 06 pass on arm64 and x86-64 macOS.
- The suite files keep the counts of Linux, or the PR lists each difference and its cause.
