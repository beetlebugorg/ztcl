# ztcl

A sandboxed Tcl interpreter in Zig, with a bytecode VM and a vector path for numeric per-point scripts.

> [!WARNING]
> **Experimental.** APIs and behavior can change in any release. ztcl is not a drop-in Tcl. It is built for and used in [zslice](https://github.com/beetlebugorg/zslice). The zslice integration is in progress, and the zslice app does not ship ztcl yet.

> [!IMPORTANT]
> **AI disclaimer.** The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it. ztcl comes with no warranty. See [LICENSE](LICENSE).

**Docs:** https://beetlebug.org/ztcl/

## Status

- The test suite of Tcl 8.6.16 is the measure of compatibility. Of the 29 358 tests in the 77 files in scope, ztcl passes 24 931, fails 1 377, and 3 050 are blocked. [Compatibility](docs/compatibility.md) has the result for each of the 152 test files.
- On the 37 core test files of Tcl 9.1.0, ztcl passes 9 208 tests, fails 2 893, and skips 522. ztcl follows Tcl 8.6 and makes no claim of Tcl 9 compatibility. [Tcl 8.6 and Tcl 9](docs/tcl9.md) lists the differences and the proposed choices.

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
it.step_limit = 1_000_000;
const v = try it.eval("expr {6 * 7}");
```

## Benchmarks

Measured on an Intel Core i7-6700K (4.0 GHz, AVX2), one thread, `ReleaseFast`, 2026-11-23. Each time is the best of 11 runs of the whole process, in CPU milliseconds. The two `tclsh` builds can differ in compiler flags.

| Benchmark | ztcl | tclsh 8.6.16 | tclsh 9.1.0 |
|---|---|---|---|
| `sum.tcl` (1 million `expr` and `incr`) | 20.2 | 58.3 | 57.8 |
| `fib.tcl` (fib 25, about 250 000 calls) | 14.4 | 50.8 | 49.4 |
| `nested.tcl` (1000 x 1000, `lappend`, `llength`) | 31.8 | 73.7 | 84.7 |
| `strbuild.tcl` (500 000 `append`) | 23.0 | 63.8 | 99.2 |
| `foreach.tcl` (10 passes over 100 000 items) | 16.2 | 33.2 | 38.6 |
| `dict.tcl` (200 000 `dict incr`, 200 000 `dict get`) | 22.8 | 48.6 | 58.5 |
| `dictgrow.tcl` (200 000 new keys, 200 000 `dict get`) | 61.4 | 104.9 | 144.2 |
| `readloop.tcl` (200 000 `llength` and `lindex` on a string) | 17.7 | 27.9 | 32.7 |

The fuzzy skin `point proc` over 10 million points uses 14.8 ns for each point on the vector path and about 219 ns on the normal path. [Testing](docs/testing.md) has all results.

## Compatibility

ztcl follows the 12 language rules of Tcl and the core commands of Tcl 8.6: lists, strings, dicts, arrays, `expr`, `format`, `scan`, `binary`, `regexp`, namespaces, `try`, `apply`, `lmap`, `upvar`, and `uplevel`. The [language reference](docs/language.md) gives the status of each command.

**Intentionally absent:** files, sockets, `exec`, `clock`, C extensions, and Tk. A script has no command that reaches the host. `puts` writes to a callback of the embedder.

## Known limits

- A big integer has at most 2^20 bits. Tcl has no fixed limit.
- A write to an existing key of a dict that another value shares copies the dict.
- The arena frees memory only at `compact`, `reset`, or `deinit`, so one long evaluation that makes many strings grows it. The memory limit stops the script.
- Regular expressions use the first alternative that matches. Tcl prefers the longest match.

## Documentation

- [Design](docs/design.md): values, bytecode, and point procs
- [Language reference](docs/language.md)
- [Embedding in Zig](docs/embedding.md)
- [Testing and benchmarks](docs/testing.md)
- [Tcl 8.6 and Tcl 9](docs/tcl9.md)
- [Roadmap](docs/roadmap.md)
- [Release process](docs/release.md)
- [References](docs/references/tcl.md)

## License

ztcl itself is licensed under [BSD-2-Clause](LICENSE). zslice (AGPL-3.0-or-later) uses ztcl. The zslice license applies to zslice only. ztcl credits Tcl and its other sources in [References](docs/references/tcl.md).
