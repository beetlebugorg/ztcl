# Changelog

## Unreleased

- Renames the namespace of the built-in modules from `zt` to `ztcl`: `ztcl::json`, `ztcl::hello`, and `ztcl::hellonet`. The old names `zt::json`, `zt::hello`, and `zt::hellonet` are deprecated aliases until v0.4.0-beta. `package require` of an old name loads the module and makes the old namespace an ensemble of the same commands.
- Adds `ztcl build --wasm`: a copy of `ztcl.wasm` with Tcl scripts and read-only files in it, made with no Zig toolchain. `run()` and `Interp.run()` of `ztcl.mjs` run the scripts, and `allow: ["file"]` turns on `source` and `open` for the files under `//zipfs:/app/`. See `docs/webassembly.md`.
- Adds an interactive shell to the runner, with a line editor of its own: Emacs and vim keys, multi-line input, history in `~/.ztcl_history` with prefix and fuzzy search, completion, colors as you type, hints, bracketed paste, results in color, and `~/.ztclrc`. See `docs/shell.md`.
- Fixes the `exec` allowlist. A script could write a file at the path of an allowed program, and `exec` ran that file. `exec` now resolves each program to one full host path, checks the allowlist on that path, and runs only that path. A file below the root folder runs only from the new list `Interp.exec_host.allow_root` (runner flag `--exec-allow-root`). A relative `PATH` entry is an error.
- Fixes a crash of `file delete -force` and `file copy` on a deep tree in a coroutine. Both commands now walk the tree with a list on the heap, pay steps for each entry, and stop at 2048 levels. `file copy` of a folder into itself is now an error before the copy.
- Adds the module `ztcl::json`: a parser on the simdjson algorithm, `get` and `exists` on a path, `encode` with a schema, the builders, `pretty`, and the tcllib names `json` and `json::write`. See `docs/modules/json.md`.
- Adds tier 1 and tier 2 of the JIT on arm64 macOS.
- Runs threads in WebAssembly with Web Workers: `web/ztcl-threads.mjs` and the modules `ztcl-threads.wasm` and `ztcl-async.wasm`.
- Adds channels, sockets, the event loop, `exec`, and the root folder jail on arm64 macOS, and the jail on x86-64 Windows.
- Makes `thread::send` and `tpool::post` faster: an event wakes its futex only when a thread waits, and the job table of a pool has no tombstones.

## v0.2.0-beta (2026-11-25) and earlier

- Adds the capability `thread`: `thread::*`, `tsv::*`, `tpool::*`, and the mutexes and conditions of the Thread package, with limits for each thread. See `docs/threads.md`.
- Adds tier 2 of the JIT on x86-64 Linux, off by default: `--jit-tier2` and `--jit-tier2-count`.
- Adds the WebAssembly guide, the JS module, and the playground.
- Adds the module table and `package require` of built-in modules.
- Kills the whole process tree of a pipeline at the time limit: a cgroup on Linux, or a scan of /proc when the embedder cannot make a cgroup. A process that calls `setsid` no longer stays.
- Adds the `ztcl` package, the runner, the WebAssembly library, and the release workflows.
- Licensed under BSD-2-Clause.
- Adds the npm package `@beetlebug/ztcl`, with types, and a workflow that publishes it on a version tag. `Interp.create` and `WorkerInterp` load the `ztcl.wasm` file next to `ztcl.mjs` when no source is given. See `docs/dev/npm.md`.
- Names the instruction budget the step limit: the runner flag `--max-steps`, the `Interp` field `step_limit`, and the WebAssembly export `ztcl_set_step_limit`. This replaces the flag of v0.1.0-alpha. The error text is now `step limit reached`.
- Adds a hash table for dicts with 16 or more keys. A new key is amortized O(1).
- Adds `Interp.compact`, a reset that keeps the commands, procs, namespaces, and point programs.
- Adds big integers up to 2^20 bits. An integer that overflows 64 bits no longer wraps.
- Adds `bench/dictgrow.tcl` and the Tcl 9.1.0 baseline in `docs/dev/tcl9.md`.
- Adds inline bytecode for `llength`, `lindex`, `string length`, and `string index`.
- Dispatches bytecode from the end of each handler. The script benchmarks use 4% to 27% less CPU time from this change.
- Caches the list parse of a string for `llength` and `lindex`, and adds `bench/readloop.tcl`. That benchmark goes from 571 ms to 17.7 ms.
- Runs the noise of the point proc fast path on 8 lanes, keeps the corner hashes within a cell, and reads the input columns with no copy. The fuzzy skin proc goes from 23.5 to 14.8 ns for each point.
- Writes and parses the decimal text of big integers in steps of 19 digits. The Tcl 8.6.16 suite goes from 26 s to 4 s.
- Fixes the arena growth of `lindex` with an integer index.
- Replaces the arena with a heap and a conservative mark-and-sweep collector. A long loop holds a flat memory size. A value from `eval` is valid until the next call into the interpreter. Adds `Interp.hold`, `release`, `addRoot`, `removeRoot`, `collect`, the field `gc_on`, and the runner flags `--gc`, `--gc-stress`, and `--report`.
- Starts a collection only at a safe point, and makes a host call with no `enterHost` run with no collection.
- Reclaims memory in the WebAssembly build with precise roots at bytecode safe points. Adds `ztcl_set_gc_stress`, `tools/wasm-mem.mjs`, and `tools/gc-fuzz.py`.
- Adds tier 1 of a JIT compiler on x86-64 Linux, off by default: the build option `-Djit`, `Interp.enableJit`, and the runner flags `--jit`, `--jit-threshold`, and `--jit-stats`. Adds `tools/jit-diff.sh`, `tools/jit-perf.sh`, `tools/jit-asm-golden.sh`, the scripts of `tests/jit/`, and `suite.sh -j`.
- Moves each bytecode handler to a function that the interpreter and the JIT share.
- Fixes a use after free in `compact` for a string in `tcl_precision`. `compact` now returns `error.InterpBusy` for an interpreter with TclOO objects and ends each `hold`.
- Fixes variable traces and `vwait` on an `upvar` link to an array element.
- Fixes an overflow of `%` on the smallest integer and an underflow in the regexp match of a sequence.
- Adds `tools/suite.sh -a`, a scope for each of the 152 test files of Tcl 8.6.16, and `docs/dev/compatibility.md`. A test that did not run counts as blocked.
- Adds `tcl::mathop`, `tcl::mathfunc`, `tcl::prefix`, `trace`, `case`, `unknown`, `namespace path`, `namespace unknown`, `namespace forget`, ensemble options, array searches, `upvar` to an array element, `tcl_precision`, `binary` uuencode, the `subst` options, and the `-during` option of `try`.
- Makes the `string` commands and glob patterns work on characters.
- Adds `coroutine`, `yield`, `yieldto`, and `tailcall`. The stack switch exists for x86-64 Linux, arm64 macOS, and x86-64 Windows.
- Replaces the regular expression engine: ARE, ERE, BRE, and literal syntax, lookahead, and the leftmost-longest match in linear time.
- Adds the `%n$` forms of `scan` and `format`.
- Adds the optional capabilities `package` and `interp`, off by default.
- Adds the optional capabilities `clock`, `channels`, and `file`. `clock` uses a host callback. `file` and channels stay inside one root folder.
- Adds the optional event loop: `after`, `vwait`, `update`, `fileevent`, `interp bgerror`, and non-blocking channels. The time comes from a host callback.
- Adds the optional capability `socket` with a network policy from the embedder: `loopback` (the default), an allowlist of hosts, address ranges, and ports, or `any`.
- Adds TclOO: `oo::class`, `oo::object`, `oo::define`, `oo::objdefine`, `oo::copy`, `my`, `self`, `next`, `nextto`, mixins, filters, forwards, and `info object` and `info class`.
- Adds `encoding` to the channel capability, for the encodings with no table.
- Adds the optional capability `exec`: `exec`, `pid`, and command pipelines, with a program list, a time limit, and a fixed environment from the embedder. `exec` is not sandboxed.
- Adds `timerate` to the `clock` capability.
- Fixes `format`: the `h` size, `%#x` and `%#b` of zero, `%#e`, `%#f`, and `%#g`, a `*` width with `%n$`, zero padding of strings, and widths in characters.
- Accepts the options of `interp create` in any place.
- Adds `time` to the `clock` capability, and the runner option `--tclsh` for the child processes of the Tcl tests.
- Adds a test-only suite runner with commands that call real ztcl code.
- Sets the error codes of Tcl for arithmetic, argument counts, list syntax, and lookups.
- Fixes the eval after a memory error. A top-level eval that starts above the memory limit runs a collection first, and runs with only the hard cap while the live data stays above the limit.
- Adds channels, the event loop on sockets, and `socket` for x86-64 Windows. A file open gives an error there until the root folder jail is ported.
- Adds channels, the event loop on sockets, and `socket` for x86-64 Windows.
- Adds `file` and file channels for x86-64 Windows, with a root folder jail that walks each path and gives an error for each reparse point.
