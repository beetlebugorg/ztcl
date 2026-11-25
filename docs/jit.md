# The JIT

ztcl has an optional compiler from bytecode to machine code for x86-64 Linux and arm64 macOS. It is off by default. A script gives the same output, the same step counts, and the same memory count with the JIT on and off.

## Turn it on

```sh
ztcl --jit script.tcl                  # tier 1
ztcl --jit --jit-tier2 script.tcl      # tier 1 and tier 2
ztcl --jit --jit-tier2 --jit-stats script.tcl
```

In Zig:

```zig
if (!it.enableJit(.{})) {
    // No JIT in this build or on this system. The interpreter runs each script.
}
```

`enableJit` returns false on WebAssembly, on other targets, in a build with `-Djit=false`, and on a system that refuses executable memory. On arm64 macOS, an app with the hardened runtime needs the entitlement `com.apple.security.cs.allow-jit`. [Embed in Zig](embedding.md#the-jit) has the options.

| Flag | Use |
|---|---|
| `--jit` | Turns on tier 1. |
| `--jit-threshold N` | The calls of a proc before it compiles (default 2). A body with a loop compiles at its first call. |
| `--jit-tier2` | Turns on tier 2 for hot loops. |
| `--jit-tier2-count N` | The passes of a loop before tier 2 compiles it (default 1000). |
| `--jit-stats` | Prints what compiled. |

## What it speeds up

- **Tier 1** compiles the bytecode of a proc, or of a script outside a proc, to machine code. Integer arithmetic, compares, `incr`, and some list operations run inline. Other instructions call the handlers of the interpreter.
- **Tier 2** compiles a hot loop of a proc a second time. Integer and double variables stay in registers for the whole loop. A failed type check exits to tier 1 at the same instruction.

Numeric loops gain the most. Code that spends its time in string, dict, or I/O commands gains little.

## Numbers

A 10-million-pass integer loop in a proc (`sum.tcl` of the [quick start](quickstart.md)), wall time on an Intel Core i7-6700K:

| Run | Time |
|---|---|
| `tclsh` 8.6.16 | 413 ms |
| ztcl, interpreter | 157 ms |
| ztcl `--jit` | 64 ms |
| ztcl `--jit --jit-tier2` | 15 ms |

User CPU instructions of the whole process, in millions, from `perf stat -e instructions:u`, x86-64 Linux, `ReleaseFast`, 2026-11-24:

| Script | Interpreter | `--jit` | `--jit --jit-tier2` | tclsh 8.6.16 |
|---|---|---|---|---|
| `sum.tcl` | 283.8 | 90.9 | 15.0 | 684.3 |
| `dsum.tcl` | 688.8 | 555.9 | 16.6 | 1212.5 |
| `nested.tcl` | 333.4 | 123.5 | 55.3 | 934.0 |
| `foreach.tcl` | 206.9 | 80.4 | 40.6 | 387.1 |
| `fib.tcl` | 151.0 | 106.0 | 106.0 | 600.9 |

[Performance](performance.md#the-jit) has all scripts and the larger programs.

## Safety

- Code memory is never writable and executable at once.
- A verifier checks each bytecode before it compiles.
- No value from a script goes into the machine code as a constant.
- The step limit and the memory limit hold in machine code, exactly as in the interpreter.
- A script cannot turn the JIT on or detect it.

The tests compare the JIT with the interpreter on the whole Tcl test suite, on random programs from a differential fuzzer (`zig build jit-fuzz`), and in stress modes that force the rare paths. One difference stays: an endless recursion can go deeper before the nesting error, because a JIT call uses less native stack.
