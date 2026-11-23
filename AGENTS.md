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
| `tools/suite.sh -t core-8-6-16` | Runs the Tcl test suite. |

## Rules

1. Run `zig build test` before each commit. The tests must pass.
2. Run the suite before a change to the interpreter is done. The pass count of a file must not drop. The total is 19 780 for the 37 core files of `core-8-6-16`. Use `tools/suite.sh -a` for all 152 files.
3. Add no command that reaches the host: no files, sockets, processes, clock, or environment. `puts` goes to the embedder callback.
4. Keep scripts deterministic. Output depends only on the script, the seed, and the embedder inputs.
5. Keep the limits: step limit, memory, nesting, and native stack. A script must not crash the host.
6. Keep the fast path and the slow path of a point proc equal, bit for bit.
7. Add no dependency. Copy no code from Tcl or from a project with a copyleft license. Credit each source in `docs/references/`.
8. Start each source file with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
9. Stop only your own processes, by PID.

## Commits and merges

- Follow the commit rules in WRITING.md.
- Add no attribution lines, co-author lines, or session links.
- Merge by rebase only. Keep merge commits out of PR branches.
