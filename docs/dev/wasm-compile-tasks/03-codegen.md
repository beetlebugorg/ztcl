# Task 03: the code generation and `ztcl compile`

Platform: shared/web.

## Goal

`ztcl compile FILE -proc NAME -o OUT.wasm` makes the module of the design for one point proc, with SIMD. `-simd off` makes the scalar form.

## Files

- `tests/point/`: the fixed procs of the tests in `src/point.zig` (`fuzzy` and the proc with branches), as `.tcl` files.
- `src/point_wasm.zig`: the generator from a `Program` to the function `run`, the layout of the memory, the globals, and the custom section `ztcl.point`.
- `src/cli/main.zig`: one hunk: the subcommand `compile`. It installs `point` on its interpreter, runs FILE, and compiles NAME. Options: `-o`, `-simd on|off`, `-max-mem BYTES` (default 16 MiB), `-features a,b,...`.
- `tools/point-wasm-diff.sh` and `tools/point-wasm-diff.mjs`: compile the fixed procs of the point tests, run each module in Node.js on random points, and compare with `Program.run` and `point.runSlow`. The native side runs through a small Zig tool that writes the outputs as hex bits.

## Rules

- Each operation uses a wasm instruction only when the instruction gives the bits of `Program.run` for each input. Write the reason for each such operation in a comment. All other operations call the runtime one lane at a time.
- `noise3` runs only for the lanes in its mask.
- The last block can be short. The lanes past `n` are not read and not written.
- Present and missing columns follow `in_mask` and `out_mask` as in `point.Points`.

## Acceptance

```sh
CAP zig build test
CAP zig build && zig-out/bin/ztcl compile tests/point/fuzzy.tcl -proc fuzzy -o zig-out/fuzzy.wasm
wasm-tools validate zig-out/fuzzy.wasm
CAP tools/point-wasm-diff.sh                    # SIMD and scalar, each fixed proc
```

Gate: no difference in bits.
