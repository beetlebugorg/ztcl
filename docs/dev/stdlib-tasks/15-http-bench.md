# Task 15: The HTTP/1.1 speed gates

Platform: Linux.

## Goal

The TechEmpower plaintext and JSON tests against Go, Node, and uvicorn, and the profile work to reach the gates.

## Files

- `bench/stdlib/http/` : the app of ztcl and the other servers.
- Fixes in `src/http/` from the profile.

## Test sources

- The rules of the TechEmpower plaintext and JSON tests.

## Acceptance

```sh
CAP python3 -I tools/bench-stdlib.py --only http --check bench/stdlib/gates.tsv
```

Gates:

- The HTTP/1.1 gates of the design: requests per second, p99 latency, and the cost of the compute limit.
