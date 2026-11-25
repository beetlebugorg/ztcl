# Task 49: quic-interop-runner, the HTTP/3 gates, fuzzing, and the ports

Platform: Linux.

## Goal

The interop gate, the speed gate, the fuzz gate, and the ports to macOS and Windows of HTTP/3.

## Files

- `tools/quic-interop/` (new): the Docker image of the ztcl endpoint for quic-interop-runner.
- `bench/stdlib/h3/`.

## Test sources

- quic-interop-runner and its test cases. `h2load` with HTTP/3 support.

## Acceptance

```sh
CAP tools/quic-interop.sh
CAP python3 -I tools/bench-stdlib.py --only h3
```

Gates:

- The test cases of the design (handshake, transfer, retry, resumption, zero-RTT, HTTP/3, multiplexing, key update, migration) pass against at least three other stacks, as client and as server.
- The user sets the HTTP/3 speed gate from the first numbers.
- QUIC needs its own external review before it is on by default.
- Size: the `http3` row of the design.
