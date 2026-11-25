# Task 10: the benchmarks against `tclsh` with Thread

Platform: Linux.

## Goal

Wall times of ztcl and of `tclsh` 8.6.16 with Thread 2.8.11.

## Files

- `bench/thread_map.tcl`, `bench/thread_pipe.tcl`, `bench/thread_tsv.tcl`, `bench/thread_tpool.tcl` (new).
- `docs/dev/testing.md`: the table.

## Benchmarks

1. A parallel map: a list of 1 000 000 integers in 8 parts, a proc on each element, the results back.
2. A pipeline of 4 threads with 100 000 messages.
3. 8 threads with 100 000 `tsv::incr` each on one element, then on 8 elements.
4. `tpool` with 8 workers and 100 000 small jobs.

## Acceptance

Each time is the best of 5 runs, with the CPU model and the date. A slower result than `tclsh` gets its cause in the table.
