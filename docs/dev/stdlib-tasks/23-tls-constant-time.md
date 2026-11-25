# Task 23: The constant-time tests and the machine code review

Platform: shared.

## Goal

Tests of the constant-time rules of the design, and a review of the machine code of the hot paths.

## Files

- `tools/tls-timing.zig` (new): a test in the style of dudect for the record open (good and bad tags), the finished check, the padding scan, and the ticket open.
- `docs/tls.md`: the list of secret-dependent functions, the review of their machine code on x86-64 and arm64, and the result.

## Test sources

- The dudect method (Reparaz, Balasch, Verbauwhede).

## Acceptance

```sh
CAP zig build tls-timing -- --samples 10000000
```

Gates:

- The t-test value stays below 4.5 for each function after 10 million samples.
- The review finds no branch and no memory index on a secret in the listed functions, or the PR fixes each one.
