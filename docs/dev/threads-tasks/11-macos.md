# Task 11: arm64 and x86-64 macOS

Platform: macOS.

## Goal

The thread commands build and pass their tests on macOS.

## Rules

1. Check the futex wait of `std.Io.Threaded` on macOS (`__ulock_wait`).
2. Check the stack size of a thread (32 MiB) and the stack scan of the collector on a thread that is not the main thread.
3. The channel commands are absent on macOS, so `thread::transfer` is absent.

## Acceptance

The common commands, and the tests of tasks 02 to 05 and 08, with the JIT on and off.
