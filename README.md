# ztcl

A sandboxed Tcl interpreter in Zig, with a bytecode VM and a vector path for numeric per-point scripts.

> [!WARNING]
> **Experimental.** APIs and behavior can change in any release. ztcl is not a drop-in Tcl. It is built for and used in [zslice](https://github.com/beetlebugorg/zslice). The zslice integration is in progress, and the zslice app does not ship ztcl yet.

> [!IMPORTANT]
> **AI disclaimer.** The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it. ztcl comes with no warranty. See [LICENSE](LICENSE).

## Status

- The test suite of Tcl 8.6.16 is the measure of compatibility. ztcl passes 19 241 tests, fails 1 041, and skips 544 over 37 test files.
- All measurements are against Tcl 8.6.16. ztcl makes no claim of Tcl 9 compatibility. See the [roadmap](docs/roadmap.md).

## Example

```tcl
proc fib {n} {
    if {$n < 2} { return $n }
    expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]}
}
puts [fib 20]
```

```sh
zig build run -- fib.tcl
```

A `point proc` compiles one body to a vector program that runs over blocks of 1024 points. An embedder installs the command. The `ztcl` runner does not have it.

```tcl
point proc fuzzy {x y z feature} {
    if {$feature ne "outer_wall"} { return }
    set n [noise3 $x $y [expr {$z * 4}]]
    offset [expr {$n * 0.3}]
}
```

[Embedding](docs/embedding.md) has the complete Zig program.

## Build and install

ztcl needs Zig 0.16.0.

| Command | What it does |
|---|---|
| `zig build` | Installs `zig-out/bin/ztcl`. |
| `zig build test` | Runs the unit tests. |
| `zig build run -- script.tcl` | Runs a script. With no file, it reads commands from stdin. |
| `zig build bench` | Runs the point proc benchmark. |
| `zig build wasm` | Builds `zig-out/lib/ztcl.wasm`. |

Homebrew (available after the first release):

```sh
brew install beetlebugorg/tap/ztcl
```

The runner has a default memory limit of 2 GiB. `--mem N` changes it.

## Use as a Zig package

```sh
zig fetch --save git+https://github.com/beetlebugorg/ztcl
```

```zig
// build.zig
const dep = b.dependency("ztcl", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ztcl", dep.module("ztcl"));
```

```zig
const ztcl = @import("ztcl");

var it: ztcl.Interp = undefined;
try it.init(gpa);
defer it.deinit();
it.fuel = 1_000_000;
const v = try it.eval("expr {6 * 7}");
```

## Benchmarks

Measured on an Intel Core i7-6700K (4.0 GHz, AVX2), one thread, `ReleaseFast`, 2026-11-22. The reference is `tclsh` 8.6.16. Each time is the best of 5 runs of the whole process, in CPU milliseconds.

| Benchmark | ztcl | tclsh 8.6.16 |
|---|---|---|
| `sum.tcl` (1 million `expr` and `incr`) | 26.5 | 58.7 |
| `fib.tcl` (fib 25, about 250 000 calls) | 16.6 | 51.1 |
| `nested.tcl` (1000 x 1000, `lappend`, `llength`) | 38.2 | 74.1 |
| `strbuild.tcl` (500 000 `append`) | 35.2 | 64.0 |
| `foreach.tcl` (10 passes over 100 000 items) | 19.4 | 33.3 |
| `dict.tcl` (200 000 `dict incr`, 200 000 `dict get`) | 36.1 | 48.9 |

The fuzzy skin `point proc` over 10 million points uses 23 ns for each point on the vector path and 241 ns on the normal path. [Testing](docs/testing.md) has all results.

## Compatibility

ztcl follows the 12 language rules of Tcl and the core commands of Tcl 8.6: lists, strings, dicts, arrays, `expr`, `format`, `scan`, `binary`, `regexp`, namespaces, `try`, `apply`, `lmap`, `upvar`, and `uplevel`. The [language reference](docs/language.md) gives the status of each command.

**Intentionally absent:** files, sockets, `exec`, `clock`, C extensions, and Tk. A script has no command that reaches the host. `puts` writes to a callback of the embedder.

## Known limits

- Integers are 64 bits and wrap. Tcl continues with big integers.
- A dict is a list of pairs with no hash table, so a dict that grows key by key has quadratic cost.
- The arena frees memory only at `reset` or `deinit`, so a long script that makes many strings grows it. The memory limit stops the script.
- Regular expressions use the first alternative that matches. Tcl prefers the longest match.

## Documentation

- [Design](docs/design.md): values, bytecode, and point procs
- [Language reference](docs/language.md)
- [Embedding in Zig](docs/embedding.md)
- [Testing and benchmarks](docs/testing.md)
- [Roadmap](docs/roadmap.md)
- [Release process](docs/release.md)
- [References](docs/references/tcl.md)

## License

ztcl itself is licensed under [BSD-2-Clause](LICENSE). zslice (AGPL-3.0-or-later) uses ztcl. The zslice license applies to zslice only. ztcl credits Tcl and its other sources in [References](docs/references/tcl.md).
