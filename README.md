# ztcl

A sandboxed Tcl interpreter in Zig, with a bytecode VM and a vector path for numeric per-point scripts.

> [!WARNING]
> **Experimental.** APIs and behavior can change in any release. ztcl is not a drop-in Tcl. It is built for and used in [zslice](https://github.com/beetlebugorg/zslice). The zslice integration is in progress, and the zslice app does not ship ztcl yet.

> [!IMPORTANT]
> **AI disclaimer.** The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it. ztcl comes with no warranty. See [LICENSE](LICENSE).

**Docs:** https://beetlebug.org/ztcl/

## Status

- ztcl aims to become a complete drop-in replacement for Tcl. It is not one yet. The sandbox stays the default, and host access stays an explicit capability of the embedder.
- The test suite of Tcl 8.6.16 is the measure of compatibility. Of the 46 494 tests in all 152 files, ztcl passes 37 383 on the suite runner (80.4 %), fails 3 044, and 6 067 are blocked. Of the 29 990 tests in the 77 files in scope, it passes 27 182, fails 1 031, and 1 777 are blocked. Of those passes, 1 735 need a test-only command. With the default runner, the pass rate in scope is 84.9 %. [Compatibility](docs/compatibility.md) has the result for each test file.
- On the 37 core test files of Tcl 9.1.0, ztcl passes 9 298 tests, fails 2 799, and skips 529. ztcl follows Tcl 8.6 and makes no claim of Tcl 9 compatibility. [Tcl 8.6 and Tcl 9](docs/tcl9.md) lists the differences and the proposed choices.

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
| `zig-out/bin/ztcl --jit script.tcl` | Runs a script with the JIT on (x86-64 Linux). |

On x86-64 Linux, ztcl has an optional compiler from bytecode to machine code. It is off by default. `--jit` turns it on in the runner, and `Interp.enableJit` turns it on in the library. A script gives the same output with the JIT on and off. See [the JIT plan](docs/jit.md).

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

The fuzzy skin `point proc` over 10 million points uses about 15 ns for each point on the vector path and about 230 ns on the normal path. [Testing](docs/testing.md) has all results.

## JIT compiler (experimental)

ztcl has a JIT compiler for x86-64 Linux. It is off by default.

- Build: `zig build -Djit=true`. This is the default on x86-64 Linux. WebAssembly and other targets use the interpreter only.
- Run: `ztcl --jit script.tcl`. `--jit-threshold N` sets the number of calls before a proc compiles, and `--jit-stats` prints what compiled.
- Tier 1 compiles the bytecode of a proc body or of a script outside a proc to machine code. Each instruction calls the same handler as the interpreter. Integer arithmetic, compares, `incr`, and some list paths run inline.
- Tier 2 compiles a hot loop of a proc a second time. Integer and double variables stay in registers for the whole loop, and other instructions call the helpers of tier 1. A failed check exits to tier 1 at the same instruction. `--jit-tier2` turns tier 2 on, and `--jit-tier2-count N` sets the passes of a loop before it compiles (1000 by default). Tier 2 is off by default. A script outside a proc stays in tier 1.
- The step limit and the memory limit are exact, as in the interpreter. A JIT run gives the same results and the same step counts as the interpreter on the whole Tcl test suite.
- The code memory is never writable and executable at once. A verifier checks each bytecode before it compiles, and no script value goes into the machine code.
- An endless recursion can go deeper with the JIT before the nesting error, because a JIT call uses less native stack.

User CPU instructions of the whole process, in millions, on the scripts in `bench/`. Measured on 2026-11-24 with `perf stat -e instructions:u`, `ReleaseFast`, x86-64 Linux.

| Script | Interpreter | `--jit` | `--jit --jit-tier2` | tclsh 8.6.16 |
|---|---|---|---|---|
| `sum.tcl` | 283.8 | 90.9 | 15.0 | 684.3 |
| `dsum.tcl` | 688.8 | 555.9 | 16.6 | 1212.5 |
| `nested.tcl` | 333.4 | 123.5 | 55.3 | 934.0 |
| `foreach.tcl` | 206.9 | 80.4 | 40.6 | 387.1 |
| `dict.tcl` | 280.7 | 194.9 | 188.6 | 555.3 |
| `dictgrow.tcl` | 647.7 | 590.3 | 588.3 | 825.5 |
| `readloop.tcl` | 145.3 | 93.3 | 85.3 | 302.3 |
| `strbuild.tcl` | 322.9 | 252.5 | 243.1 | 812.4 |
| `fib.tcl` | 151.0 | 106.0 | 106.0 | 600.9 |

Three programs of kostya/benchmarks with `bench.b`, measured on one build on 2026-11-24. The ratio is the instructions of ztcl over the instructions of tclsh 8.6.16, from `perf stat -e instructions:u`. The counts of tclsh come from an earlier run on the same day. With `small.b`, each output of ztcl equals the output of tclsh.

| Program | Interpreter | `--jit` | `--jit --jit-tier2` |
|---|---|---|---|
| `bf.tcl` | 0.363 | 0.245 | 0.247 |
| `bf_oo.tcl` | 0.463 | 0.373 | 0.374 |
| `base64/test.tcl` | 0.701 | 0.701 | 0.701 |

Wall time in seconds, the best of 5 runs, each run pinned to one core with `taskset`. `bf.tcl` and `bf_oo.tcl` use `small.b`: `bench.b` with one level of the inner loops removed. One run with `bench.b` lasts minutes. Other jobs shared the machine, so the times are rough: two series of `base64` differed by up to 40 %, with equal instruction counts.

| Program | Interpreter | `--jit` | `--jit --jit-tier2` | tclsh 8.6.16 |
|---|---|---|---|---|
| `bf.tcl small.b` | 0.84 | 0.65 | 0.65 | 2.73 |
| `bf_oo.tcl small.b` | 4.22 | 3.40 | 3.70 | 8.17 |
| `base64/test.tcl` | 4.88 | 5.78 | 5.81 | 5.84 |

[The JIT design](docs/jit.md) has the plan and the gates.

## Compatibility

ztcl follows the 12 language rules of Tcl and the core commands of Tcl 8.6: lists, strings, dicts, arrays, `expr`, `format`, `scan`, `binary`, `regexp`, namespaces, `try`, `apply`, `lmap`, `upvar`, and `uplevel`. The [language reference](docs/language.md) gives the status of each command.

**Absent by default:** files, sockets, `exec`, `clock`, and the event loop. A script has no command that reaches the host. `puts` writes to a callback of the embedder. An embedder can turn on each of these as a capability. `exec` is not sandboxed: it gives a script the full power of the user. C extensions and Tk are out of scope.

## Known limits

- A big integer has at most 2^20 bits. Tcl has no fixed limit.
- A write to an existing key of a dict that another value shares copies the dict.
- The collector is conservative and does not move a block. A value from `eval` is valid until the next call into the interpreter, and `hold` keeps it longer. A number that looks like an address keeps a dead block. With the collector on, the place where the memory limit stops a script can differ between two runs. `--gc off` makes it exact. The WebAssembly build collects only at bytecode safe points, so a long loop inside `lmap` or another general command holds its garbage until the command ends.
- Regular expressions use the first alternative that matches. Tcl prefers the longest match.

## Documentation

- [Design](docs/design.md): values, bytecode, and point procs
- [JIT compiler](docs/jit.md)
- [Language reference](docs/language.md)
- [Embedding in Zig](docs/embedding.md)
- [WebAssembly](docs/webassembly.md): the JS module, the examples, and the [playground](https://beetlebug.org/ztcl/playground/)
- [Testing and benchmarks](docs/testing.md)
- [Tcl 8.6 and Tcl 9](docs/tcl9.md)
- [Roadmap](docs/roadmap.md)
- [Release process](docs/release.md)
- [References](docs/references/tcl.md)

## License

ztcl itself is licensed under [BSD-2-Clause](LICENSE). zslice (AGPL-3.0-or-later) uses ztcl. The zslice license applies to zslice only. ztcl credits Tcl and its other sources in [References](docs/references/tcl.md).
