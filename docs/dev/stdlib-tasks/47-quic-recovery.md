# Task 47: Loss recovery and congestion control

Platform: Linux.

## Goal

RFC 9002 loss detection, the probe timeout, and the NewReno controller, with pacing.

## Files

- `src/quic/recovery.zig` (new).

## Test sources

- RFC 9002 and its appendix pseudocode as the reference of the behavior.

## Acceptance

```sh
CAP zig build quic-recovery-test
```

Gates:

- A test proxy with delay, loss, and reorder gives the throughput and the RTT estimates that the PR reports, within the bounds of the RFC rules.
