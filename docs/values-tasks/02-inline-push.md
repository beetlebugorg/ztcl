# Task 02: an inline push on the value stack

## Goal

The parser pushed each value with `ArrayList.append`, a call for each value. Check the capacity inline and call a cold function only to grow.

## Files

- `src/json/build.zig`: `push` and `close`.

## Rules

- The stack grows as an `ArrayList` grows. A start of 256 places that doubles gave twice the page faults of main on twitter.

## Acceptance

- 5 % fewer instructions for one parse of each file.
- Heap bytes per JSON byte equal to main.
