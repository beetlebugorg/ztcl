# Changelog

## Unreleased

- Adds the modules `ztcl::pdf` and `ztcl::typeset`. `ztcl::pdf` writes PDF files with embedded subsets of TrueType fonts, kerning and ligatures, PNG and JPEG images, links, and an outline. `ztcl::typeset` breaks paragraphs with the total-fit algorithm of Knuth and Plass, hyphenates with the patterns of Liang, and lays out Markdown into PDF pages. See [Typesetting in Tcl](docs/typesetting.md) and [PDF documents](docs/pdf.md).
- Adds `book/` and `zig build book`: the sample chapter of the ztcl book, typeset by `ztcl::typeset`, with each example run and checked at build time.
- Adds the module `ztcl::vm`: a small Linux guest on Virtualization.framework (macOS), a KVM monitor of ztcl (x86-64 Linux), or the Windows Hypervisor Platform (x86-64 Windows), with no QEMU. A script runs programs in the guest with `exec` (`-binary` for binary input and output), gives it folders with `-share`, and talks to it over vsock. `listen` takes the connections of a guest to the host. `-net nat` gives the guest a virtio-net device on a user-mode NAT of ztcl (KVM and macOS), and the network policy of the interpreter checks each host address and the DNS. On Windows a share is virtio-fs with a DAX window. `image fetch` and `image update` get a signed guest image over HTTPS (the highest release when no version is given), the store checks its signature and its dm-verity root, and `create -image` boots it from a pool of booted guests. `snapshot` writes a KVM guest to a file, and `create -snapshot F -count N` restores it as N clones. See [the guide](docs/vm.md) and [the module page](docs/modules/vm.md).
- Adds isolation levels for threads: `thread::create -isolation process` runs a thread in a child process in the sandbox of Linux, macOS, or Windows, and `-isolation vm` runs it in a guest of `ztcl::vm` on KVM. `thread::transfer` gives an isolated thread a file or a socket. `thread::create -caps LIST` gives a thread a subset of the capabilities of its creator. See [Isolated threads](docs/isolation.md).
- Adds the module `ztcl::meter`: the compute units, wall time, CPU time, memory, and I/O of each thread and child interpreter, and signed records of them. `thread::create -meter NAME` counts a thread in a meter. See [Metering](docs/metering.md).
- Adds the module `ztcl::agent`: an LLM agent loop in an isolated thread with no capability. The loop has only the data and the tools that the host gives it. See [Sandboxed agents](docs/agents.md).
- Adds the module `ztcl::tls`: `ztcl::tls socket` opens a TLS 1.3 client channel on the TLS code of ztcl, with X.509 chain checks, the trust store of the system, SNI, and ALPN. The TLS 1.3 server handshake is in `src/tls/` with the RFC 8448 traces, and no command uses it yet. See [TLS 1.3](docs/tls.md) and [the module page](docs/modules/tls.md).
- Adds the module `ztcl::disasm`: the bytecode of a proc, a lambda, or a script under the source line of each command, and with `machine` the machine code of the JIT for each range. See [the module page](docs/modules/disasm.md).
- Adds `ztcl debug --dap`, a debugger for editors on the Debug Adapter Protocol: breakpoints, steps, the stack, hot reload, pause, error breakpoints with the filters `error` and `uncaught`, and a stop for each thread. See [Debugging](docs/debugging.md).
- Adds a Tcl release switch: Tcl 8.6 by default, and Tcl 9.1 with `ztcl --tcl 9.1`, `interp create -tcl 9.1`, or `Interp.create({tcl: "9.1"})`. The 9.1 release has the new list commands, the math functions, `lsearch -stride`, `switch -integer`, `array default`, the new `expr` operators and number forms, and the `-profile` option of channels. See [Tcl 9.1](docs/tcl91.md).
- Adds libztcl, a shared library with the C API of Tcl 8.6: the stubs tables, `load` of C packages, and the slots of objects, interps, commands, channels, namespaces, hash tables, and parse. A program that links libtcl8.6 runs on it with no new build. `zig build libztcl --prefix PREFIX` installs a development kit with the headers, the stub library, `tclConfig.sh`, and the `pkg-config` files. See [libztcl](docs/libztcl.md).
- Opens serial ports as channels on Linux, macOS, and Windows, with the `fconfigure` options `-mode`, `-handshake`, `-xchar`, `-ttycontrol`, `-ttystatus`, and `-queue` of Tcl. In the browser, `ztcl-host.wasm` gives the ports of Web Serial as channels.
- Adds the commands `dom` and `web::` to `ztcl-host.wasm`. A script in a web page reads and changes the elements below one root element, runs a script for an event, and calls the Web APIs of the page through a table of their Web IDL. See [Tcl in a web page](docs/dom.md) and [the module page](docs/modules/web.md).
- Adds `ztcl::notify` (the notifications of the system), `ztcl::mac::keychain` and `ztcl::mac::defaults` on macOS, and `ztcl::win::credential` and `ztcl::win::folder` on Windows. Each command has its own capability.
- Adds `interp cancel` and the C functions `Tcl_CancelEval` and `Tcl_Canceled`.
- Keeps the surrogate halves of a string, and adds the `unicode` encoding of channels and `source -encoding`.
- Adds an asynchronous I/O loop for the HTTP server of issue [#27](https://github.com/beetlebugorg/ztcl/issues/27): io_uring with an epoll fallback on Linux, and kqueue on macOS. Adds the server side of HTTP/2 with HPACK (RFC 7541), checked with h2spec and the HPACK corpus. No Tcl command uses them yet.
- Adds a PKGBUILD for Arch Linux in `packaging/arch/ztcl-git`. It builds `main` with the `zig` package of Arch. See [Install](docs/install.md#arch-linux).
- Changes `errorInfo` to the form of tclsh 8.6: one command for each evaluation, with the context lines of `eval`, `uplevel`, loop bodies that Tcl does not compile, `switch` arms, and `try` handlers, and the line of the failed command in the proc body. Adds `-errorstack`, `info errorstack`, and `info hostname`. The list of `info` subcommands is the list of Tcl 8.6. `set` of a variable in a namespace that does not exist is an error.
- Adds `coroutine` on arm64 Linux, with the stack switch of arm64 macOS. The arm64 Linux JIT job compares the output of `coroutine.tcl` and `owned_lists.tcl` with `tclsh` again.
- Fixes the memory limit check of a growth in place: it uses the full new length, as a copy to a new block does. Before, a script stopped at a different point with the JIT on and off when the system allocator grew a block in place in one mode only. The JIT fuzzer found it on arm64 Linux (seed 662). `jit-fuzz --replay FILE` runs a found file again, `--mem-runs N` gives each program N random memory limits, and `tests/jit/replay/` has the program.
- Adds the JIT on arm64 Linux, with tier 1 and tier 2. The region flushes the caches over the written pages with the line sizes of `CTR_EL0`. CI runs the unit tests, `tools/jit-diff.sh`, and the JIT fuzzer on an arm64 Linux runner for each pull request. `tools/jit-diff.sh` reads `JIT_DIFF_NO_OUT`.
- `thread::transfer` moves a file or a socket to and from an isolated thread on Linux, with `SCM_RIGHTS` as on macOS.
- Turns the JIT on by default, with tier 1 and tier 2, where the build and the system have it: in the runner, in `Interp.init`, in programs of `ztcl build`, and in threads of a creator with the JIT. A system that refuses executable memory runs the interpreter with no error. `--no-jit`, `--no-jit-tier2`, `ZTCL_JIT=off`, `Interp.disableJit`, and `ztcl build --no-jit` turn it off. `Interp.jitState` and the `state` field of `--jit-stats` give the reason. Removes the runner flags `--jit` and `--jit-tier2` and the flag `ztcl build --jit`.
- Adds record and replay to `ztcl debug`: `--record FILE` writes the inputs of the host (the clock, the clock of the event loop, the ready channels of a poll, and the bytes of each channel read) to a tape, and `--replay FILE` runs the script again with them, also with new probes. A replay that leaves the tape stops with the error code `ZTCL TAPE DIVERGED`. `--who-set VAR` and `--when VAR VALUE` answer questions over a run, and the report gives the first error ([Debugging](docs/debugging.md#record-and-replay)).
- Adds `ztcl debug`: it runs a script with probes (`--probe`) and writes a short report with the error, the stack with the locals of each frame, the probes, and the last records, within a byte budget (`--budget`). `--explain` runs the script again after an error with a probe on each line of the proc of the error, and gives the last changes of its variables. `--json` writes the report as JSON. `ztcl debug --mcp` serves the tools `ztcl_run`, `ztcl_explain`, `ztcl_records`, and `ztcl_eval` over MCP. `ztcl::probe add` gets `-locals` ([Debugging](docs/debugging.md)).
- Adds the module `ztcl::probe`: probes on a proc, a line of a proc body, a command, a variable, or each error, with `-if`, `-capture`, `-stack`, and the limits `-count`, `-every`, and `-rate`. The records go in a ring buffer outside the memory limit, and `ztcl::probe records` gives them as dicts or JSON lines, with `-where`, `-since`, `-first`, and `-last`. A probe uses no compute units of the script. A body with probes runs in the interpreter, and the other procs keep their machine code ([module page](docs/modules/probe.md)).
- Adds the module `ztcl::vt`: the state of a terminal on libghostty-vt 1.0.2, which the build compiles from source with `-Dsimd=false` and links statically. A script feeds it bytes and reads back the rows, the cells, the cursor, the modes, and the dirty rows. It needs no capability. `-Dmod-vt=false` leaves it out. See `docs/modules/vt.md`.
- Adds `ztcl::pty` on Windows with a pseudo console (ConPTY): `spawn`, `resize`, `size`, `status`, `kill`, and `close`, with the program in the Job Object of `exec`. `kill` with `INT` writes Ctrl-C, and each other signal ends the job.

- Adds `exec`, `pid`, and command pipelines (`open "|cmd"`) on Windows. A bare name goes through the `PATH` and `PATHEXT` of `exec_host.env`, each program gets one full path before it starts, and the allowlist compares that path. A `.bat` or `.cmd` file is an error, because `cmd.exe` reads its arguments with other rules. Each pipeline is a Job Object, so a kill or the time limit ends each process that a program started. See `docs/dev/exec-windows.md`.

- Adds `ztcl::open` behind the new capability `launch` (`--allow launch`): a URL with the scheme `http`, `https`, or `mailto`, or a file, in the default app of the host. A file also needs `file`, and its path goes through the jail or host mode. On Windows it uses `ShellExecuteExW` on the final path of the file, and a file of a type that runs as code is an error. `Interp.launch_host` lets an embedder open the target itself. Linux and macOS give `ZTCL OPEN UNAVAILABLE` until their backends land.
- Adds `ztcl::win::registry` on Windows behind the new capability `registry`: `get`, `set`, `type`, `delete`, `keys`, and `values`, with the value types of the `registry` package of Tcl. It reaches only the keys of `Interp.registry_allow` (runner flag `--registry-allow`) and the keys below them.

- Renames the step limit to the compute limit, counted in compute units. The error is `compute limit reached`. The runner flags are `--compute`, `--thread-compute`, and `--threads-compute`. The Zig field is `Interp.compute_limit`, the thread limits are `compute_limit` and `total_compute`, the wasm exports are `ztcl_set_compute_limit` and `ztcl_compute_left`, and the JS option is `computeLimit`. The `--report` line gives `compute=`. The old names are gone. See `docs/limits.md#the-compute-limit`.
- Adds a host mode for the file commands: `file`, `open`, `glob`, `cd`, `pwd`, and `source` use the real paths of the host and follow symlinks, as tclsh does. The runner turns it on when `--allow` gives `file` or `channels` and no `--root DIR` came before it. `--root` turns the root folder jail on. An embedder gets the jail unless it calls `fsroot.setHost`. A child interp of a host-mode parent is in host mode too. Windows has drive letters and UNC paths.

- Renames the namespace of the built-in modules from `zt` to `ztcl`: `ztcl::json`, `ztcl::hello`, and `ztcl::hellonet`. The old names `zt::json`, `zt::hello`, and `zt::hellonet` are gone.
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
