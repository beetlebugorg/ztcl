# Task 41: The SQLite tests and the speed gate

Platform: Linux.

## Goal

The subset of the SQLite test files that uses only the commands of the design, and the speed gate against `tclsh` with the SQLite package.

## Files

- `tools/sqlite-tests.sh` : the list of files and the pass counts.
- `bench/stdlib/sqlite/`.

## Test sources

- The test files of SQLite of the same version. `tclsh` 8.6 with the `sqlite3` package built from the same amalgamation.

## Acceptance

```sh
CAP tools/sqlite-tests.sh
CAP python3 -I tools/bench-stdlib.py --only sqlite --check bench/stdlib/gates.tsv
```

Gates:

- The pass count of each file in the list is the gate, and each failure has a cause in the PR.
- The SQLite gates of the design: the cost of each row and of each cached insert is at most the cost of `tclsh`.
