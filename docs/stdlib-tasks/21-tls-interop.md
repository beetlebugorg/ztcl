# Task 21: The interop matrix and the negative tests

Platform: Linux.

## Goal

The full interop matrix of the design in CI, and the negative tests in the style of tlsfuzzer.

## Files

- `tools/tls-interop.sh` : the matrix against `openssl s_server`, `openssl s_client`, and `curl`.
- `tests/tls/negative/` (new): the negative cases of the design as scripted peers in Zig.
- `tools/tlsfuzzer.sh` (new): runs tlsfuzzer as an outside program against the server, with the list of its TLS 1.3 scripts in the PR.

## Test sources

- tlsfuzzer (its TLS 1.3 scripts). OpenSSL 3. curl.

## Acceptance

```sh
CAP tools/tls-interop.sh
CAP zig build tls-negative
CAP timeout 3600 tools/tlsfuzzer.sh
```

Gates:

- Each cell of the matrix passes.
- Each negative case gets the alert of the RFC and closes.
- Each tlsfuzzer script of the list passes, or the PR gives the cause of each failure and the user accepts it.
