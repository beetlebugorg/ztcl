# ztcl

Modern Tcl for the AI era. ztcl is an alternative implementation of Tcl in Zig, built to be the fastest and most complete one. It runs Tcl 9.1 scripts, and Tcl 8.6 scripts with `--tcl 8.6`, with exact compute and memory limits, a JIT compiler that is on by default, real threads, microVM isolation, and a WebAssembly build for the browser. The current release is 1.0.0-beta.1.

**Docs:** https://beetlebug.org/ztcl/ · **Playground:** https://beetlebug.org/ztcl/playground/

- **Designed with AI in mind.** `ztcl::agent` runs an LLM agent loop in an isolated thread with tools that are Tcl commands. A thread can run in its own microVM. `ztcl debug` serves MCP tools to an agent.
- **Measured on real tasks.** On 9 real-world tasks, ztcl is 1.8 times as fast as `tclsh` 8.6.16 at the median, and slower on one (base64 end to end). It is faster than Python 3.14 on 6 of 11 tasks, and slower on base64, CSV, a regex over a web log, and word frequency. Go is faster on 7 of 11, and Zig on all 11. [bench/compare](bench/compare/README.md) has the programs, and [Performance](docs/performance.md) has the charts. A 50 times speedup over `tclsh` holds only for a narrow micro benchmark: an integer loop in one proc.
- **Safe by default.** A script has no file, socket, or process access until your program turns on a capability. The compute limit and the memory cap are exact.
- **Small.** One static binary. Its one dependency outside the Zig standard library is libghostty-vt, which the build compiles from source into the binary for `ztcl::vt`.
- **Portable.** Linux, macOS, Windows, WebAssembly in the browser, and Node.js.
- **One binary for your program.** `ztcl build` puts the runtime and your scripts in one static binary for Linux, macOS, or Windows.
- **Made for code from an agent.** The [Learn course](docs/learn/01-read-a-command.md) teaches Tcl to review agent code, and the [command reference](docs/reference/README.md) and its `api.json` give an agent each synopsis, error, and capability.

Coming, each in an open issue: the isolation levels `wasm` and `vm-confidential` for threads ([#209](https://github.com/beetlebugorg/ztcl/issues/209)), ztcl as a host of wasm modules ([#202](https://github.com/beetlebugorg/ztcl/issues/202)), and https and an HTTP/2 server ([#27](https://github.com/beetlebugorg/ztcl/issues/27)).

## Install

```sh
brew install beetlebugorg/tap/ztcl     # macOS and Linux
npm install @beetlebug/ztcl            # WebAssembly, for the browser and Node.js
```

[Install](docs/install.md) has the release binaries and the build from source.

## Example

<!-- live -->
```tcl
proc fib {n} {
    if {$n < 2} { return $n }
    expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]}
}
puts [fib 20]
```

```sh
$ ztcl fib.tcl
6765
$ ztcl --compute 1000 fib.tcl
fib.tcl:2: compute limit reached
```

## Documentation

- [Quick start](docs/quickstart.md) and [the language](docs/language.md)
- [Limits and capabilities](docs/limits.md), [threads](docs/threads.md), and [the JIT](docs/jit.md)
- [Isolated threads](docs/isolation.md), [Linux guests](docs/vm.md) with `ztcl::vm`, and [sandboxed agents](docs/agents.md)
- [Debugging](docs/debugging.md), [Tcl 9.1 and Tcl 8.6](docs/tcl91.md), and [TLS 1.3](docs/tls.md)
- [Build a program](docs/build.md): one native binary for Linux, macOS, or Windows, from any host, with `ztcl build`
- [Strip a program](docs/strip.md): a runtime with only the commands, capabilities, and modules that the scripts use, with `ztcl build --strip`
- [Embed in Zig](docs/embedding.md) and [WebAssembly](docs/webassembly.md)
- [libztcl](docs/libztcl.md): build C programs and Tcl extensions against ztcl, as libtcl8.6
- [Performance](docs/performance.md) and the [FAQ](docs/faq.md)
- For contributors: [docs/dev/](docs/dev/README.md) has the plans, the task lists, and the test results.

## Status

ztcl is experimental, and its APIs can change in any release. It passes 38,054 of the 47,133 tests of the Tcl 8.6.16 suite, so it is not yet a drop-in replacement for Tcl. The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it. The [issues](https://github.com/beetlebugorg/ztcl/issues) and the [milestones](https://github.com/beetlebugorg/ztcl/milestones) have the roadmap.

## Contact

Write to [opensource@beetlebug.org](mailto:opensource@beetlebug.org) about ztcl. Open an [issue](https://github.com/beetlebugorg/ztcl/issues) for a bug or a request, and report a security problem as [SECURITY.md](SECURITY.md) says.

## License

BSD-2-Clause. See [LICENSE](LICENSE). [References](docs/references/tcl.md) credits Tcl and the other sources.
