# The JIT

ztcl has a compiler from bytecode to machine code for x86-64 Linux and arm64 macOS. It is on by default where the build and the system have it. [Targets](targets.md) lists the JIT of each target. A script gives the same output, the same counts of compute units, and the same memory count with the JIT on and off.

## Turn it off

```sh
ztcl script.tcl                        # tier 1 and tier 2
ztcl --no-jit-tier2 script.tcl         # tier 1
ztcl --no-jit script.tcl               # the interpreter
ZTCL_JIT=off ztcl script.tcl           # the interpreter
ztcl --jit-stats script.tcl            # the counts and the state of the JIT
```

In Zig, `Interp.init` turns the JIT on:

```zig
try it.init(gpa);
it.disableJit(); // the interpreter only
```

When the system refuses executable memory, the interpreter runs each script with no error. Examples are SELinux `deny_execmem`, `PR_SET_MDWE`, a seccomp filter, and a hardened macOS runtime with no entitlement `com.apple.security.cs.allow-jit`. WebAssembly, other targets, and a build with `-Djit=false` have no JIT. `Interp.jitState` and the `state` field of `--jit-stats` give the reason: `on`, `not_built`, `refused`, or `off`. [Embed in Zig](embedding.md#the-jit) has the options.

| Flag | Use |
|---|---|
| `--no-jit` | Turns the JIT off. |
| `--jit-threshold N` | The calls of a proc before it compiles (default 2). A body with a loop compiles at its first call. |
| `--no-jit-tier2` | Turns tier 2 off. |
| `--jit-tier2-count N` | The passes of a loop before tier 2 compiles it (default 1000). |
| `--jit-stats` | Prints what compiled, and the state of the JIT. |

## What it speeds up

- **Tier 1** compiles the bytecode of a proc, or of a script outside a proc, to machine code. Integer arithmetic, compares, `incr`, and some list operations run inline. Other instructions call the handlers of the interpreter.
- **Tier 2** compiles a hot loop of a proc a second time. Integer and double variables stay in registers for the whole loop. A failed type check exits to tier 1 at the same instruction.

Numeric loops gain the most. Code that spends its time in string, dict, or I/O commands gains little.

## Numbers

A 10-million-pass integer loop in a proc (`sum.tcl` of the [quick start](quickstart.md)), wall time on an Intel Core i7-6700K:

| Run | Time |
|---|---|
| `tclsh` 8.6.16 | 413 ms |
| ztcl `--no-jit` | 157 ms |
| ztcl `--no-jit-tier2` | 64 ms |
| ztcl (the default, tier 1 and tier 2) | 15 ms |

User CPU instructions of the whole process, in millions, from `perf stat -e instructions:u`, x86-64 Linux, `ReleaseFast`, 2026-11-24:

| Script | `--no-jit` | `--no-jit-tier2` | default | tclsh 8.6.16 |
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
- The compute limit and the memory limit hold in machine code, exactly as in the interpreter.
- A script cannot turn the JIT on or off, or detect it.

The tests compare the JIT with the interpreter on the whole Tcl test suite, on random programs from a differential fuzzer (`zig build jit-fuzz`), and in stress modes that force the rare paths. One difference stays: an endless recursion can go deeper before the nesting error, because a JIT call uses less native stack.
