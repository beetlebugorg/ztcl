# Task 40: The `sqlite3` command, the statement cache, and the limits

Platform: shared.

## Goal

The Tcl API of the design, compatible with the binding of SQLite, with the statement cache, the steps through the progress handler, the limits of `sqlite3_limit`, and the capability.

## Files

- `src/sqlite/cmd.zig` (new).
- `docs/modules/sqlite.md` (new).

## Test sources

- The manual page of the Tcl interface of SQLite. `tclsqlite.test` of the same SQLite version as an outside file.

## Acceptance

```sh
CAP zig-out/bin/ztcl tests/stdlib/sqlite.test
CAP tools/sqlite-tests.sh
```

Gates:

- Each method of the design list works as in the manual page, with the bind forms `$name`, `:name`, and `@name`.
- A query in an endless recursive CTE stops at the step limit.
- Without `sqlite`, the command is absent. Without `file`, only `:memory:` opens, and `ATTACH` of a file fails.
