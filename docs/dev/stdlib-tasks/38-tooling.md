# Task 38: `ztcl test`, `ztcl::bench`, and `ztcl prof`

Platform: shared.

## Goal

The test runner, the benchmark command, and the profiler of the design.

## Files

- `src/cli/main.zig`: the subcommands `test`, `bench`, and `prof`. One hunk for the dispatch.
- `src/tool/` (new).

## Test sources

- The `tcltest` manual page. The folded stack format of flame graphs.

## Acceptance

```sh
CAP zig-out/bin/ztcl test tests/stdlib
CAP zig-out/bin/ztcl prof bench/fib.tcl > /tmp/fib.folded
```

Gates:

- `ztcl test -j 4` gives the same counts as `-j 1` on `tests/stdlib`.
- Two runs of `ztcl prof` on one script give the same output.
- Size: the `tooling` row of the design.
