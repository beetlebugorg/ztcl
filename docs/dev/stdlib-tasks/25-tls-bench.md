# Task 25: The TLS speed gates

Platform: Linux.

## Goal

The TLS gates of the design against Go and OpenSSL.

## Files

- `bench/stdlib/tls/`.

## Test sources

- `openssl s_time`, `openssl speed -evp`, and a Go program with `crypto/tls`.

## Acceptance

```sh
CAP python3 -I tools/bench-stdlib.py --only tls --check bench/stdlib/gates.tsv
```

Gates:

- The TLS gates of the design: full and resumed handshakes per second, and bulk throughput for both AEADs.
- HTTPS plaintext requests per second over TLS at least 0.7 of Go.
