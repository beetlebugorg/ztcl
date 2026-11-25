# Task 13: The worker pool: one interpreter for each worker, and the limits of a request

Platform: shared.

## Depends on

Tasks 01 to 05 of the threads plan, and task 08 for the coroutine targets.

## Goal

The worker pool of the design on the threads plan: each worker loads the app script, runs each request in a coroutine, and has the limits of the design.

## Files

- `src/http/workers.zig` (new): the pool on the group and the workers of `src/thread.zig` and `src/tpool.zig`.
- `src/http/server.zig`: the dispatch to the pool.

## Test sources

- The tests of the limits: a handler in an endless loop, a handler that allocates without end, a handler that waits forever, and a handler that calls `exit`.

## Acceptance

```sh
CAP zig-out/bin/ztcl tests/stdlib/http-limits.test
CAP timeout 900 tools/http-chaos.sh   # runaway handlers among 1000 good requests per second for 10 minutes
```

Gates:

- A runaway handler ends with the status of the design. Each other request of the run succeeds.
- A worker that passes its memory limit restarts, and the requests of other workers do not fail.
- The step count of each request is exact under `-concurrency 64`: a test compares the count with a run under `-concurrency 1`.
- The decision 5 of the user is the default of `-concurrency`.
