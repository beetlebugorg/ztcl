# Zig 0.17.0

ztcl builds with Zig 0.17.0. This page lists the changes of the move from 0.16.0, so an embedder or another repository can make the same changes.

## Build

- `build.zig.zon` has `.minimum_zig_version = "0.17.0"`. Each CI workflow sets `ZIG_VERSION` or the `version` of `setup-zig` to 0.17.0.
- The tags of `std.builtin.OptimizeMode` are lower case: `.debug`, `.safe`, `.fast`, and `.small`. The old names are declarations that 0.18.0 removes, so an enum literal such as `.ReleaseFast` is an error. The command line still accepts `-Doptimize=ReleaseSafe`.
- `b.args` is gone. The build script runs before the build runner reads the arguments after `--`. A run step gets them with `run.addPassthruArgs()`.

## Language

- The array repeat operator `**` is gone. A run of one value is `@splat`, for example `const t: [256]bool = @splat(false);`. The two lookup tables of `src/json/index.zig` use `std.simd.repeat(32, table)`. The repeated strings of the tests are plain literals.
- `@typeInfo` of an enum has `field_names` and `field_values` in place of `fields`. A struct has `field_names`, `field_types`, and `field_attrs`. A loop over the fields of an enum goes over the two arrays: `inline for (info.field_names, info.field_values) |name, value|`.
- `zig fmt` rewrites `@intFromEnum` to `@backingInt` and `@enumFromInt` to `@fromBackingInt`. CI runs `zig fmt --check build.zig src`, so the files of `src` have the new names.

## Standard library

- `std.meta.fields` is a compile error. The layout code uses `std.meta.fieldNames` and `@FieldType`.
- `std.StaticBitSet` has the constants `.empty` and `.full` in place of `initEmpty()` and `initFull()`.
- `Allocator.dupeZ(u8, s)` is `dupeSentinel(u8, s, 0)`. `std.fmt.bufPrintZ(buf, f, args)` is `bufPrintSentinel(buf, f, args, 0)`.
- `std.os.linux.wait4` and `waitpid` write the status to an `*i32`. The macOS shim of `wait4` in `src/sys.zig` has the same type. The callers convert the status to `u32` with `@bitCast` for the `W` functions.

## Collector

A precise build scans the words of each `Interp` struct. The struct has its own `Heap`, and the field `lo` of the heap is the address of the lowest span. With Zig 0.17.0, the first block of that span is the first value that a test allocates, so the scan of `lo` kept the value alive after `release`. The test "a held value survives 100 collections and an unheld value is freed" failed with `-Dgc-precise=true`. `markInterpWords` in `src/gc.zig` now skips the words `lo` and `hi` of the heap.

## Checks

These checks ran on 2026-11-26 on an x86_64 Linux machine with 8 cores. Each one compares the branch with main built by Zig 0.16.0 on the same machine. The suite and `tools/jit-diff.sh` ran on main cc53538 (before a later rebase), and the bench scripts ran on main e96fc66.

- `zig build test` passes in Debug and ReleaseSafe with `-Djit=false`, with the JIT, and with `-Dgc-precise=true`. The runner builds for `aarch64-macos`, `x86_64-macos`, and `x86_64-windows`. `aarch64-windows` fails to link `jit-probe` with an undefined `__clear_cache`, and Zig 0.16.0 fails the same way.
- `tools/suite.sh -a`: 35,679 passes with 0.17.0 and with 0.16.0, and each file has the same pass count.
- `tools/jit-diff.sh`: 182 runs compared, 0 differ.
- `node tools/wasm-smoke.mjs`, `tools/wasm-web.mjs`, and `tools/wasm-bundle.mjs` pass. `node npm/test/run.mjs node browser cdn` passes in Chromium.
- The scripts of `bench/`, best of 5 interleaved runs, CPU time of the process in ms:

| Script | 0.17.0 | 0.16.0 | Ratio |
|---|---|---|---|
| `dictgrow.tcl` | 71.6 | 74.2 | 0.966 |
| `dict.tcl` | 22.5 | 22.6 | 0.994 |
| `dsum.tcl` | 47.5 | 47.9 | 0.992 |
| `fib.tcl` | 14.6 | 14.1 | 1.036 |
| `foreach.tcl` | 15.6 | 16.1 | 0.966 |
| `nested.tcl` | 36.2 | 37.2 | 0.973 |
| `readloop.tcl` | 12.6 | 12.0 | 1.047 |
| `strbuild.tcl` | 21.2 | 22.3 | 0.950 |
| `sum.tcl` | 18.6 | 19.7 | 0.941 |

The `thread_*.tcl` scripts need the `thread` capability, and the plain runner stops them with "can't find package Thread" on both versions. For `readloop.tcl` with 2,000,000 passes, `perf stat -e instructions:u` gives 1,488,968,040 instructions with 0.17.0 and 1,493,346,007 with 0.16.0, and 6 percent more cycles with 0.17.0. The instruction count is equal, so the difference is in the placement of the machine code of `vm.exec`.
