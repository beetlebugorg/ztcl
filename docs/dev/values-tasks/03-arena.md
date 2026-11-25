# Task 03: a cache of empty spans, then the arena

## Goal

Make one block for each container and the arena of the parse faster in time as well as in instructions. A measure on 2026-11-25 (`docs/dev/values.md`) gave 3 to 4.5 times the page faults of main. The sweep gives each empty span back to the backing allocator, and this is the likely cause. Step 2 checks it.

## Steps

1. `src/heap.zig`: keep empty spans of each size up to a cap (for example 1/8 of the live bytes, at most 4 MiB). The counter counts the kept spans, so the memory limit sees them. A collection under memory pressure gives them back.
2. Measure main with step 1. Gate: no `bench/` script and no JSON mode slower.
3. Make each container one block (`allocList`) in `src/json/build.zig`.
4. Add the arena: chunks of 8 KiB to 64 KiB for the containers of one parse. A list above 8 KiB gets its own block.
5. Find why the mark count of a parse loop grows with the new layouts.

## Rules

- A chunk is an ordinary heap block, so the memory count and the memory limit see it.
- The steps of a parse do not change.

## Acceptance

- Page faults of 200 parses of each file equal to main or lower.
- No mode of `bench_ztcl.tcl` slower than main by more than 3 %.
- A loop that keeps one field of each of 50 parses holds no more than 2 times the memory of main. Give the number.
