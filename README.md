# ztcl

A fast, sandboxed Tcl interpreter in Zig. ztcl runs Tcl 8.6 scripts with exact compute and memory limits, a JIT compiler that is on by default, real threads, and a WebAssembly build for the browser.

**Docs:** https://beetlebug.org/ztcl/ · **Playground:** https://beetlebug.org/ztcl/playground/

- **Fast.** The bytecode interpreter is 1.2 to 2.7 times as fast as `tclsh` 8.6.16 on the benchmark scripts. With the JIT, an integer loop is 50 times as fast (a GitHub `ubuntu-latest` runner, 2026-11-27, [Performance](docs/performance.md)).
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
- [Debugging](docs/debugging.md), [Tcl 9.1](docs/tcl91.md), and [TLS 1.3](docs/tls.md)
- [Build a program](docs/build.md): one native binary for Linux, macOS, or Windows, from any host, with `ztcl build`
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
