# Task 02: the runtime module and the function append

Platform: shared/web.

## Goal

The build makes `point_rt.wasm`: the math functions of the point path, `noise3`, and `bound`, from the same Zig functions as the interpreter. `src/wasm_link.zig` appends new functions to a copy of it.

## Files

- `src/point_rt.zig`: the exports of the runtime. Each one calls the function of `point.zig`, `expr.zig`, or `noise.zig` that the interpreter calls. It has no copy of a function body.
- `src/point.zig`: one hunk: the functions that `Program.run` calls for `fn1`, `fn2`, `clamp`, `lerp`, and `noise3` become `pub`, with no change to their bodies.
- `build.zig`: builds `src/point_rt.zig` for `wasm32-freestanding` with `simd128`, with no imports, and embeds the bytes in the `ztcl` module.
- `src/wasm_link.zig`: reads the runtime with `wasm_out.zig`, adds types, functions, a memory, globals, exports, and a custom section, and writes the module again. The runtime functions keep their indices.
- `tools/point-rt-diff.mjs`: calls each runtime function in Node.js on random `f64` inputs and on the special values (NaN, -0, the infinities, the subnormals), and compares the bits with the output of a native test.

## Acceptance

```sh
CAP zig build test
CAP zig build point-rt
wasm-tools validate zig-out/lib/point_rt.wasm
wasm-tools print zig-out/lib/point_rt.wasm | grep -c '(import'     # 0
CAP node tools/point-rt-diff.mjs --count 1000000
```

Gate: no difference in bits. If a function differs, report the function, the input, and the two outputs, and stop.
