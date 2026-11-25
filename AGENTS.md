# Agent instructions

ztcl is an experimental, sandboxed Tcl interpreter in Zig. It is built for zslice and has no dependency on it. It uses only the Zig standard library.

Read [WRITING.md](WRITING.md) before you write code comments, commits, or PRs. Read [docs/design.md](docs/design.md) before you change the interpreter.

## Commands

Use Zig 0.16.0. Run each test, bench, and suite command under a memory cap:

```sh
systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- <command>
```

| Command | What it does |
|---|---|
| `zig build` | Builds the runner. |
| `zig build test` | Runs the unit tests. |
| `zig build run -- script.tcl` | Runs a script. |
| `zig build bench` | Runs the point proc benchmark. |
| `python3 -I tools/bench.py --tclsh tclsh` | Compares the scripts in `bench/` with a tclsh. |
| `zig build wasm` | Builds the WebAssembly library. |
| `node tools/wasm-web.mjs zig-out/lib/ztcl.wasm` | Tests `web/ztcl.mjs` and the Node.js example. |
| `tools/suite.sh -t core-8-6-16` | Runs the Tcl test suite. |
| `tools/suite.sh -j` | Runs the suite with the JIT at threshold 0. |
| `tools/jit-diff.sh` | Compares the JIT with the interpreter on the test scripts. |
| `tools/jit-perf.sh --check off` | Checks that the interpreter did not slow down. |

## Rules

1. Run `zig build test` before each commit. The tests must pass.
2. Run the suite before a change to the interpreter is done. The pass count of a file must not drop. The total is 19 877 for the 37 core files of `core-8-6-16`, and 37 383 for all 152 files with the suite runner. Use `tools/suite.sh -a` for all 152 files.
3. The default interpreter, the library default, and the wasm build have no command that reaches the host: no files, sockets, processes, clock, timers, or environment. `puts` goes to the embedder callback. These optional capabilities are off by default, and only an embedder can turn them on: `clock`, `package`, `interp`, channels, `file`, `socket`, `exec`, and the event loop (`after`, `vwait`, `update`, `fileevent`). A test proves that each one is absent by default. `file` and channels stay inside one root folder from the embedder. `socket` follows the network policy of the embedder: `loopback` (the default), an allowlist of hosts, address ranges, and ports, or `any`. `sys.resolve` is the only name lookup, and the policy check runs on each resolved address, on the address of each connection, and on each peer of a server. The tests and the suite stay offline: they use only addresses of the local machine. A child interp never has more capabilities than its parent. `exec` is its own capability, and `file` does not turn it on. A process of `exec` is outside the root folder and outside each limit, so `exec` gives a script the full power of the user. Do not describe `exec` as sandboxed. zslice never turns it on.
4. With no capability on, scripts are deterministic. Output depends only on the script, the seed, and the embedder inputs.
5. Keep the limits: step limit, memory, nesting, and native stack. A script must not crash the host.
6. Keep the fast path and the slow path of a point proc equal, bit for bit.
7. Add no dependency. Copy no code from Tcl or from a project with a copyleft license. Credit each source in `docs/references/`.
8. Start each source file with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
9. Stop only your own processes, by PID.
10. The JIT and the interpreter must agree: the same output, errors, steps, and memory count for each script. Run `tools/jit-diff.sh` and `tools/suite.sh -j` after a change to `src/vm.zig` or `src/jit/`.

## Commits and merges

- Follow the commit rules in WRITING.md.
- Add no attribution lines, co-author lines, or session links.
- Merge by rebase only. Keep merge commits out of PR branches.
