# Task 01: The module table, `package require` from memory, and the build flags

Platform: shared.

## Goal

Built-in modules that `package require` loads from memory, with a build flag for each module. The table has no real module yet: a test module `zt::hello` shows the path.

## Files

- `src/modules.zig` (new): the `Module` type, the table, and `install` for each interpreter.
- `src/pkg.zig`: the small `package require`, `present`, `provide`, and `versions` that see only the built-in modules (decision 1).
- `build.zig`: `-Dbatteries=core|std|full`, `-Dmod-NAME`, the dependency rules between modules, and a build option with the list.
- `src/interp.zig`: the new capability bits `random`, `env`, and `sqlite` (`fetch` is wasm only). One hunk in `Capability`.
- `src/main.zig`: `--allow` accepts the new names. One hunk.
- `tests/stdlib/modules.test` (new).

## Rules

1. A module installs once for each interpreter. A second `package require` gives the version and runs no script.
2. The embedded script of a module runs with the limits of the interpreter.

## Test sources

- The core test files `package.test` and `safe.test`: their pass counts must not drop.

## Acceptance

```sh
CAP zig build test -Dbatteries=core
CAP zig build test -Dbatteries=full
CAP zig-out/bin/ztcl tests/stdlib/modules.test
CAP tools/suite.sh -a
```

Gates:

- `-Dbatteries=core` gives a binary within 1 KB of `main` after `strip`.
- The tests show: an alias name and the new name give one install; a module that needs a capability gives the error of the design; a child gets no module of its parent; `package names` lists the modules of the build.
