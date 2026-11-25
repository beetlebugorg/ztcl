# Task 05: dict shapes

## Goal

A shape is a shared key list and index. A shaped dict holds its shape and its values. The design is in `docs/dev/values.md`.

## Rules

- A shaped dict gives the same string form, the same list view, and the same errors as the pair list.
- Behind a build flag until the full suite, the JIT differential tools, and the fuzzers pass with it on.
- The JSON task 05b uses `shapeOf` and `slotOf` for its guards.

## Acceptance

- The common commands with the flag on and off.
- Heap bytes per JSON byte of twitter and citm 15 % lower.
