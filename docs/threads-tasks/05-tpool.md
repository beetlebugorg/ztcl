# Task 05: the thread pools

Platform: shared.

## Goal

The `tpool` commands of `tpool.n`.

## Files

- `src/tpool.zig` (new).
- `src/thread.zig`: the hook of a pool worker (`Worker.pool` and its loop).

## Rules

1. A worker is a thread of the group and counts in `max_threads`. It runs `-initcmd` one time and keeps its interpreter between jobs.
2. A job result is a `Shared` tree in the pool. `tpool::get` gives it once.
3. `-idletime` ends an idle worker down to `-minworkers`. The worker runs `-exitcmd` first.
4. `tpool::release` to zero ends the workers. `endGroup` ends each pool.
5. Pool workers are absent from `thread::names`.

## Acceptance

New tests in `tests/thread/`: post, wait, get, cancel, suspend, resume, an error in a job, `-initcmd` with a proc, `-idletime`, and a post when `max_threads` is full.
