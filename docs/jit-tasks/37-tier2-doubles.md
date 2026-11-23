# Task 37: doubles

## Goal

A slot of kind `double` is in an SSE register, and `+`, `-`, `*`, `/`, and the compares on doubles are inline.

## Files

- `src/jit/tier2_types.zig`, `src/jit/tier2_x64.zig`.

## Rules

- Registers `xmm0` to `xmm5`. At most 4 slots, with `xmm4` and `xmm5` as scratch.
- `+`, `-`, `*`, `/` use `addsd`, `subsd`, `mulsd`, `divsd`. No fused multiply-add. No x87 code. The rounding mode is the default of the process.
- A division of doubles by zero follows `expr.binaryOp`: read that function and give its result. If it raises an error for a case, that case is an exit.
- An `int` and a `double` operand: `cvtsi2sd` on the integer, as `@floatFromInt` does.
- A compare uses `ucomisd`. A NaN operand is an exit, so the helper gives the result of the interpreter.
- A double that is written to a cell has the tag `.double` and the 8 bytes of the value.
- `**`, `%`, the functions, and each string form of a double stay in helpers.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-diff.sh --tier2 --stress
CAP zig build bench                        # same sum: true
CAP zig build jit-fuzz -- --tier2 --stress 32 --count 1000000
```

- A new benchmark `bench/dsum.tcl` (a loop of one million passes of `set s [expr {$s + $x * 0.5}]`): report its count in the interpreter, in tier 1, and in tier 2. The gate is the model number of task 32 plus 15 %.
- A test runs the slow path of both point procs of `src/point.zig` tests with `--jit --jit-tier2` and compares each output with the vector path, bit for bit. Rule 6 of AGENTS.md.
- The fuzzer prints each double with the shortest digits that read back, so one different bit is a difference. Add to its constants: 0.1, 1e308, 5e-324, -0.0, Inf, and NaN from `expr`.

## Must not change

The bits of each double result.
