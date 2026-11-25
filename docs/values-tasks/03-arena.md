# Task 03: a document arena

## Goal

All containers of one parse come from chunks of 64 KiB, so a container costs a pointer bump, and the collector has fewer blocks to mark and sweep.

## Files

- `src/json/build.zig`: an arena of the parse.

## Rules

- A buffer above 8 KiB gets its own block.
- A chunk is an ordinary heap block, so the memory count and the memory limit see it.
- The steps of a parse do not change.

## Acceptance

- The collector work of a loop of 20 parses is 30 % lower.
- A loop that keeps one field of each of 50 parses holds no more than 2 times the memory of main. Give the number.
