# Task 04: the mutexes, the conditions, and `thread::eval`

Platform: shared.

## Goal

`thread::mutex`, `thread::rwmutex`, `thread::cond`, and `thread::eval`.

## Files

- `src/tsync.zig` (new).

## Rules

1. A handle is a name in a table of the group (`mid0`, `wid1`, `cid2`).
2. A lock or a condition waits in slices and checks the stop flag after each slice.
3. `thread::cond wait` frees the mutex with its depth and locks it again before it returns, also after a stop.
4. `destroy` of an object in use is an error.
5. A thread that ends frees each lock that it holds.

## Acceptance

New tests in `tests/thread/`: an exclusive mutex locked twice, a recursive mutex, readers and a writer, a condition with a time limit, a producer and a consumer, `destroy` in use, and a thread that ends with a mutex held.
