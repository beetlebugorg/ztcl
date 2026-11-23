# Changelog

## Unreleased

- Adds the `ztcl` package, the runner, the WebAssembly library, and the release workflows.
- Licensed under BSD-2-Clause.
- Names the instruction budget the step limit: the runner flag `--max-steps`, the `Interp` field `step_limit`, and the WebAssembly export `ztcl_set_step_limit`. This replaces the flag of v0.1.0-alpha. The error text is now `step limit reached`.
- Adds a hash table for dicts with 16 or more keys. A new key is amortized O(1).
- Adds `Interp.compact`, a reset that keeps the commands, procs, namespaces, and point programs.
- Adds big integers up to 2^20 bits. An integer that overflows 64 bits no longer wraps.
- Adds `bench/dictgrow.tcl` and the Tcl 9.1.0 baseline in `docs/tcl9.md`.
- Adds inline bytecode for `llength`, `lindex`, `string length`, and `string index`.
- Dispatches bytecode from the end of each handler. The script benchmarks use 4% to 27% less CPU time from this change.
- Caches the list parse of a string for `llength` and `lindex`, and adds `bench/readloop.tcl`. That benchmark goes from 571 ms to 17.7 ms.
- Runs the noise of the point proc fast path on 8 lanes, keeps the corner hashes within a cell, and reads the input columns with no copy. The fuzzy skin proc goes from 23.5 to 14.8 ns for each point.
- Writes and parses the decimal text of big integers in steps of 19 digits. The Tcl 8.6.16 suite goes from 26 s to 4 s.
- Fixes the arena growth of `lindex` with an integer index.
- Adds `tools/suite.sh -a`, a scope for each of the 152 test files of Tcl 8.6.16, and `docs/compatibility.md`. A test that did not run counts as blocked.
- Adds `tcl::mathop`, `tcl::mathfunc`, `tcl::prefix`, `trace`, `case`, `unknown`, `namespace path`, `namespace unknown`, `namespace forget`, ensemble options, array searches, `upvar` to an array element, `tcl_precision`, `binary` uuencode, the `subst` options, and the `-during` option of `try`.
- Makes the `string` commands and glob patterns work on characters.
- Sets the error codes of Tcl for arithmetic, argument counts, list syntax, and lookups.
