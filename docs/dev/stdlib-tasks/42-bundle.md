# Task 42: `ztcl build` and cross targets

Platform: shared.

## Depends on

Decision 10 of the user.

## Goal

`ztcl build` of the design: the archive at the end of the runner, the read-only folder of the bundle, the recorded capabilities, and the runners of other targets.

## Files

- `src/bundle.zig` (new).
- `src/cli/main.zig`: the subcommand `build` and the start of a bundle. Hunks for each.
- `.github/workflows/release.yml`: the runner of each target as a release asset with a checksum.

## Test sources

- The zip format (APPNOTE). The Mach-O ad hoc signature rules (decision 10).

## Acceptance

```sh
CAP zig-out/bin/ztcl build examples/http/todo.tcl -o /tmp/todo && /tmp/todo --check
CAP tools/bundle-matrix.sh      # a bundle for each target, run under each system in CI
```

Gates:

- A bundle runs with no file of the source folder present.
- A flag at the command line of a bundle cannot add a capability.
- A bundle for each target runs on that target in CI.
- Size: the `build` row of the design.
