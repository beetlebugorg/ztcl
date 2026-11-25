# Task 12: x86-64 Windows

Platform: Windows.

## Goal

The thread commands build and pass their tests on Windows.

## Rules

1. Check the futex wait of `std.Io.Threaded` on Windows (`WaitOnAddress`).
2. Check the stack scan of the collector on a thread that is not the main thread.

## Acceptance

The common commands that run on Windows, and the tests of tasks 02 to 05 and 08.
