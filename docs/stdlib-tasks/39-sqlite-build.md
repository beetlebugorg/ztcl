# Task 39: The SQLite build with no libc, the VFS, and the allocator

Platform: shared.

## Depends on

Decision 9 of the user.

## Goal

SQLite in the build under `-Dmod-sqlite`: the amalgamation by decision 9, the flags of the design, the C functions in Zig, the VFS on the root folder, and the allocator on the counter.

## Files

- `vendor/sqlite/` or `build.zig.zon` (decision 9).
- `src/sqlite/libc.zig` (new): the 16 C functions that `nm -u` lists in the design, and `sqlite3_os_init` and `sqlite3_os_end`.
- `src/sqlite/vfs.zig` (new).
- `src/sqlite/alloc.zig` (new).
- `licenses/`: the public domain note of SQLite.
- AGENTS.md: rule 7 after decision 9.

## Test sources

- The SQLite documentation of the VFS, of `SQLITE_OS_OTHER`, and of `SQLITE_CONFIG_MALLOC`.

## Acceptance

```sh
CAP zig build -Dmod-sqlite=true
CAP zig build sqlite-smoke
CAP tools/size-report.sh --check
```

Gates:

- The build links with no libc on x86-64 Linux, arm64 macOS, and x86-64 Windows.
- A path outside the root folder gives `SQLITE_CANTOPEN`.
- The memory limit stops a query that builds a large result.
- The PR picks `-Os` or `-O2` for SQLite from the size and the speed gate of task 41.
- Size: the `sqlite` row of the design.
