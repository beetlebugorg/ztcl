# Task 01: the group, the threads, the messages, and the stop flag

Platform: shared.

## Goal

A host can start threads. Each thread has its own interpreter, heap, collector, JIT state, and event loop. Values cross threads as deep copies.

## Files

- `src/thread.zig` (new): `Limits`, `Group`, `Worker`, `Msg`, `Shared`, `share`, `unshare`, the group allocator, `create`, the thread main function, `serve`, `block`, `nap`, `safePoint`, `checkFlags`, `stopWorker`, `startGroup`, `endGroup`, and `setLimits`.
- `src/interp.zig`: `Capability.thread = 2048`, the fields `worker` and `thread_limits`, the call in `allow`, the call of `endGroup` at the start of `deinit` and `reset`, the copy of `thread_limits` in `reset`, and the call of `safePoint` in `memPoint`.
- `src/child.zig`: a child gets no `thread` bit.
- `src/event.zig`: the queue of a thread is a source of `doOne`, and `after N` in a thread sleeps with `nap`.
- `src/main.zig`: `--threads`, `--thread-compute`, `--thread-mem`, `--threads-compute`, and `--threads-mem`.
- `src/ztcl.zig`: `pub const thread`.

## Rules

1. The group allocator counts the bytes of all threads in one atomic counter and fails an allocation above `total_mem`.
2. A thread gets its steps from `total_compute` at its start and gives back the rest at its end.
3. `stopWorker` sets a bit of `Worker.flags` and then stores zero in `mem_limit` of the target. `safePoint` restores the limit first and reads the flags second.
4. The thread frees its own interpreter, with its JIT code, on its own thread.
5. `endGroup` stops each thread, wakes each wait, and joins each thread. No thread is detached.
6. The output of each thread goes through one lock of the group.

## Acceptance

New unit tests in `src/tests.zig` or a new `src/thread_tests.zig`:

- The default interpreter has no `thread::create`.
- A host starts a thread, sends a script, gets the result, and ends with no leak (`std.testing.allocator`).
- A list of integers and doubles crosses with its kinds.
- `deinit` of the host with a thread in `while 1 {}` ends.
