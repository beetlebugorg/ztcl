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
