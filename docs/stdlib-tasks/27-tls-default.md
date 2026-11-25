# Task 27: The findings of the review and TLS on by default

Platform: shared.

## Goal

Fix each finding of the review, and change `-Dtls` to `on` by default.

## Files

- The files of each finding.
- `build.zig`: the default of `-Dtls`.
- `SECURITY.md` and `docs/tls.md`: the state, the risks that stay, and the review.

## Test sources

- The report of the reviewer.

## Acceptance

```sh
CAP zig build tls-vectors
CAP tools/tls-interop.sh
CAP zig build tls-fuzz -- --target all --seconds 3600
CAP zig build tls-timing
```

Gates:

- Each finding has a fix and a test, or the reviewer and the user accept it as a known risk in `docs/tls.md`.
- The user approves the change of the default.
