# Task 02: the `thread::*` commands and `thread.test`

Platform: shared.

## Goal

The commands of `thread.n` that the design lists, and 17 passes in `thread.test`.

## Files

- `src/threadcmd.zig` (new).
- `src/thread.zig`: `package provide Thread 2.8.11` when `package` is on.
- `tools/suite.sh`: `thread` in the capabilities of the suite.

## Rules

1. `thread::send` without `-async` runs the messages of the own queue while it waits.
2. An error of a send has the trace of the target, then `invoked from within` and the send command.
3. `thread::exit` and `thread::cancel -unwind` set the compute limit of the thread to zero, so `catch` cannot catch them.
4. The main thread cannot be the target of `thread::cancel` and cannot use `thread::exit`.
5. A thread id has no address.
6. The error messages follow `tclsh` 8.6.16 with Thread 2.8.11.

## Acceptance

```sh
CAP tools/suite.sh thread.test           # pass 17
CAP tools/suite.sh -a                    # no file loses a test
```

New tests in `tests/thread/`: each command with good and bad arguments, a send in both directions between two threads, `-head`, `-eventmark`, `-unwindonerror`, `thread::errorproc`, and `thread::join` of a thread that ended before the join.
