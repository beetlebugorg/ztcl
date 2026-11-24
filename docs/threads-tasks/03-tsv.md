# Task 03: the shared variables

Platform: shared.

## Goal

The `tsv` commands of `tsv.n`, with a lock for each array.

## Files

- `src/tsv.zig` (new).

## Rules

1. The store lock guards only the table of the arrays. Each array has its own lock.
2. The lock of an array is recursive for its thread. `tsv::lock` holds it for its script and frees it also after an error.
3. An element is a `Shared` tree. `lappend`, `lpush` at the end, and `lpop` at the end need no parse.
4. `tsv::object` gives a command of the calling interpreter.
5. The keyed list commands read and write the form of `tsv.n`.
6. A thread that ends frees each array lock that it holds.

## Acceptance

New tests in `tests/thread/`: each command, the errors of `tclsh` with Thread, the keyed lists, `tsv::lock` with an error in its script, and 8 threads with 10 000 `tsv::incr` each on one element (the sum is exact).
