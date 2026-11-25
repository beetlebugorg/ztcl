# Task 02: one block for each container

## Goal

Each container of a parse is two allocations today. Use one block (the `ListObj` and its buffer, as `allocList` makes) and keep the capacity of the value stack between containers.

## Files

- `src/json/build.zig`: `close` and `makeDict`.

## Rules

- A dict keeps the mark `dict_len` and gets no index, as today.
- The value stack starts with a capacity from the input size and appends with no call.

## Acceptance

- 5 % fewer instructions for one parse of each file.
- Heap bytes per JSON byte lower on each file.
