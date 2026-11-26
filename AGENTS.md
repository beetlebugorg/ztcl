# Agent instructions

ztcl is an experimental, sandboxed Tcl interpreter in Zig. It is built for zslice and has no dependency on it. It uses the Zig standard library and libghostty-vt, which the build compiles from source for `ztcl::vt`.

Read [WRITING.md](WRITING.md) before you write code comments, commits, or PRs. Read [docs/dev/design.md](docs/dev/design.md) before you change the interpreter.

Put plans, task lists, reviews, and results in `docs/dev/`. The docs site publishes only the user pages that `tools/build-docs.py` lists.

## Commands

Use Zig 0.17.0. Run each test, bench, and suite command under a memory cap:

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
| `zig build wasm-shell` | Builds `zig-out/lib/ztcl-shell.wasm`: the library with the shell, for the site. |
| `node tools/wasm-shell.mjs zig-out/lib/ztcl-shell.wasm` | Tests that shell through `web/ztcl-shell.mjs`. |
| `node tools/site-shell.mjs chromium URL` | Tests the shell of a page of the built site in a headless Chromium. |
| `node tools/site-helper.mjs chromium URL` | Tests the helpers of a page of the built site and their shell in a headless Chromium. The server needs the site at `/ztcl/` and a ztk web build at `/ztk/play/`; the top of the file has the commands. |
| `node tools/site-course.mjs chromium URL` | Tests the shell of a lesson of the Learn course in a headless Chromium: the Run links, the scroll position, the saved commands, and the sheet on a small screen. |
| `tests/site.sh [site folder]` | Checks that no page of the built site shows a comment line of the Markdown, such as `<!-- run -->`, as text. |
| `tools/suite.sh -t core-8-6-16` | Runs the Tcl test suite. |
| `tools/suite.sh -j` | Runs the suite with the JIT at threshold 0. |
| `tools/jit-diff.sh` | Compares the JIT with the interpreter on the test scripts. |
| `node tools/wasm-point.mjs zig-out/lib/ztcl-simd.wasm` | Compares the point procs of the wasm library with the native `Program.run`. Build with `zig build wasm-simd point-rt` first. |
| `node tools/point-wasm-bench.mjs --check` | Compares the speed of compiled point procs with the native `Program.run`. Build with `zig build point-rt` first. |
| `tools/jit-perf.sh --check off` | Checks that the interpreter did not slow down. |

## Rules

1. Run `zig build test` before each commit. The tests must pass.
2. Run the suite before a change to the interpreter is done. The pass count of a file must not drop. The total is 19,877 for the 37 core files of `core-8-6-16`, and 37,413 for all 152 files with the suite runner. Use `tools/suite.sh -a` for all 152 files.
3. The default interpreter, the library default, and the wasm build have no command that reaches the host: no files, sockets, processes, clock, timers, or environment. `puts` goes to the embedder callback. These optional capabilities are off by default, and only an embedder can turn them on: `clock`, `package`, `interp`, channels, `file`, `socket`, `exec`, `random`, `env`, `sqlite`, `launch` (`ztcl::open`), `cext` (`load` of C packages, in a build with `-Dcext`), `registry` (`ztcl::win::registry`), and the event loop (`after`, `vwait`, `update`, `fileevent`). A test proves that each one is absent by default. A build with modules has a small `package` by default: it loads only the built-in modules of `src/modules.zig` from memory, and the full `package` command stays the capability. `file` and channels stay inside one root folder from the embedder, or use the real paths of the host in the host mode that an embedder turns on with `fsroot.setHost`. The `ztcl` and `ztk` programs use host mode by default, as tclsh does, and the root folder with `--root DIR`. `socket` follows the network policy of the embedder: `loopback` (the default), an allowlist of hosts, address ranges, and ports, or `any`. `sys.resolve` is the only name lookup, and the policy check runs on each resolved address, on the address of each connection, and on each peer of a server. The tests and the suite stay offline: they use only addresses of the local machine. A child interp never has more capabilities than its parent. `exec` is its own capability, and `file` does not turn it on. A process of `exec` is outside the root folder and outside each limit, so `exec` gives a script the full power of the user. Do not describe `exec` as sandboxed. zslice never turns it on.
4. With no capability on, scripts are deterministic. Output depends only on the script, the seed, and the embedder inputs.
5. Keep the limits: the compute limit (in compute units), memory, nesting, and native stack. A script must not crash the host.
6. Keep the fast path and the slow path of a point proc equal, bit for bit.
7. Add no dependency. The one approved dependency is libghostty-vt at the tag of `build.zig.zon`, built with `-Dsimd=false` and linked statically. Copy no code from Tcl or from a project with a copyleft license. Credit each source in `docs/references/`.
8. Start each source file with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
9. Stop only your own processes, by PID.
10. The JIT and the interpreter must agree: the same output, errors, compute units, and memory count for each script. Run `tools/jit-diff.sh` and `tools/suite.sh -j` after a change to `src/vm.zig` or `src/jit/`.

## Modules

A new `ztcl::` command goes in with its page in `docs/modules/` and a row in `docs/modules/README.md`, in the same PR.

## Commits and merges

- Follow the commit rules in WRITING.md.
- Add no attribution lines, co-author lines, or session links.
- Merge by rebase only. Keep merge commits out of PR branches.
