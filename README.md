# ztcl

A fast, sandboxed Tcl interpreter in Zig. ztcl runs Tcl 8.6 scripts with exact step and memory limits, an optional JIT compiler, real threads, and a WebAssembly build for the browser.

**Docs:** https://beetlebug.org/ztcl/ · **Playground:** https://beetlebug.org/ztcl/playground/

- **Fast.** The bytecode interpreter is 1.6 to 3.5 times as fast as `tclsh` 8.6.16 on the benchmark scripts. With the JIT, an integer loop is 28 times as fast.
- **Safe by default.** A script has no file, socket, or process access until your program turns on a capability. The step limit and the memory cap are exact.
- **Small.** One static binary with no dependency outside the Zig standard library.
- **Portable.** Linux, macOS, Windows, WebAssembly in the browser, and Node.js.

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
$ ztcl --max-steps 1000 fib.tcl
fib.tcl:2: step limit reached
```

## Documentation

- [Quick start](docs/quickstart.md) and [the language](docs/language.md)
- [Limits and capabilities](docs/limits.md), [threads](docs/threads.md), and [the JIT](docs/jit.md)
- [Build a program](docs/build.md): one native binary for Linux, macOS, or Windows, from any host, with `ztcl build`
- [Embed in Zig](docs/embedding.md) and [WebAssembly](docs/webassembly.md)
- [Performance](docs/performance.md) and the [FAQ](docs/faq.md)
- For contributors: [docs/dev/](docs/dev/README.md) has the plans, the task lists, and the test results.

## Status

ztcl is experimental, and its APIs can change in any release. It passes 37,413 of the 46,494 tests of the Tcl 8.6.16 suite, so it is not yet a drop-in replacement for Tcl. The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it. The [issues](https://github.com/beetlebugorg/ztcl/issues) and the [milestones](https://github.com/beetlebugorg/ztcl/milestones) have the roadmap.

## License

BSD-2-Clause. See [LICENSE](LICENSE). [References](docs/references/tcl.md) credits Tcl and the other sources.
