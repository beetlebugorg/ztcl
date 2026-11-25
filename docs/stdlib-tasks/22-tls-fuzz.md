# Task 22: Fuzzing of the parsers and the state machines

Platform: Linux.

## Goal

`zig build tls-fuzz` for the record parser, the handshake messages, PEM, X.509, the chain builder, and both state machines.

## Files

- `tools/tls-fuzz.zig` (new): one target for each part, a peer that sends mutated flights, and a corpus from the interop runs.
- `.github/workflows/fuzz.yml`: a run of 10 minutes for each target in each PR that changes `src/tls/`, and a nightly run of 2 hours.

## Test sources

- The corpus of task 21.

## Acceptance

```sh
CAP zig build tls-fuzz -- --target all --seconds 3600
```

Gates:

- No crash, no safety check failure, and no leak in 1 hour for each target.
- A planted bug (`-Dtls_bug=true`: a missing length check in the record parser) is found within 10 minutes.
