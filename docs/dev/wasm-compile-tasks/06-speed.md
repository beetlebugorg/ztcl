# Task 06: the speed gate

Platform: shared/web.

## Goal

The time for each point of the module is lower than the time of the vector path of the interpreter, for each fixed proc. The comparison follows the answer to question 1.

## Files

- `tools/point-wasm-bench.mjs`: runs each fixed proc on 1 000 000 points, in the module and in the reference, and gives the median ns for each point of 11 runs.
- `build.zig`: if the reference is `Program.run` in wasm, a bench build of `ztcl.wasm` that exports a call of `Program.run`. The default `zig build wasm` does not change.
- `bench/point-wasm.tsv`: the measured numbers.

## Rules

- Node.js has a JIT, so an instruction count does not apply. Use the median of 11 runs after 3 warm runs, on one core.

## Acceptance

```sh
CAP node tools/point-wasm-bench.mjs --check
```

Gate: for each fixed proc, the module with SIMD is faster than the reference. If a proc fails the gate, report the numbers and a profile, and stop.
