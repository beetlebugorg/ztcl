# Task 26: The package for the external review

Platform: shared.

## Goal

A review package: the design, the threat model, the list of files and their size, the test results, the fuzz hours, the timing results, and the known risks.

## Files

- `docs/tls.md`: the review section.
- `docs/tls-review.md` (new): the checklist for the reviewer, as `docs/jit-review.md` is for the JIT.

## Test sources

- The results of tasks 16 to 25.

## Acceptance

```sh
CAP zig build tls-vectors && CAP tools/tls-interop.sh && CAP zig build tls-fuzz -- --target all --seconds 600
```

Gates:

- The user accepts the package and sends it to the reviewer of decision 8.
