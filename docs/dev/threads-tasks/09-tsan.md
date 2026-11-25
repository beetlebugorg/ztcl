# Task 09: ThreadSanitizer

Platform: Linux.

## Goal

A build with ThreadSanitizer and a clean run of the thread tests.

## Files

- `build.zig`: a `-Dtsan` option that sets `sanitize_thread` on the module.
- A suppression file for the store of the stop flag in `mem_limit`.

## Rules

1. Check first that Zig 0.16 builds the interpreter with `sanitize_thread`. The coroutine stack switch and the stack scan of the collector can need a suppression or a build without coroutines. Report each one.
2. The suppression file names only the store of `stopWorker` and the reads of `mem_limit`.

## Acceptance

```sh
CAP zig build -Dtsan
```

The tests of tasks 02 to 08 run with no report outside the suppression file.
