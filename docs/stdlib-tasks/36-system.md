# Task 36: Files, paths, processes, the environment, arguments, and DNS

Platform: shared.

## Goal

`zt::fs`, `zt::path`, `zt::proc`, `zt::sys`, `zt::args`, `zt::dns`, and the tcllib names of `fileutil` and `cmdline`.

## Files

- `src/sys/` (new): one file for each command.
- `src/sock.zig`: `sys.resolve` calls `zt::dns` when the module is present. One hunk.

## Test sources

- RFC 1035 and RFC 3596. A local DNS server in the tests (a small Zig responder on loopback). The tcllib test files of `cmdline` and `fileutil` (rule 9).

## Acceptance

```sh
CAP zig-out/bin/ztcl tests/stdlib/system.test
CAP tools/tcllib-tests.sh cmdline fileutil
CAP zig build dns-fuzz -- --seconds 600
```

Gates:

- `zt::fs watch` reports a create, a write, a rename, and a delete on each system.
- `zt::proc run -memory` stops a child that allocates above the limit on Linux, macOS, and Windows.
- A DNS answer with an address outside the policy is dropped.
- Size: the `sys` row of the design.
