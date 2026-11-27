# Task 10: the build option, the embedder option, and the baseline

## Goal

Add each switch and each tool of the JIT with no compiler behind them. After this task, `ztcl --jit` runs and compiles no code.

## Files

- `build.zig`: the option `-Djit=<bool>`. The default is true when `src/jit.zig` has a backend for the target, and false for each other target. The WebAssembly step always passes false. Give the value to the `ztcl` module and the `fast` module as a `build_options` import.
- `src/jit.zig` (new): `pub const built` (the build option and a backend exist), `Options`, `State`, `Stats`, `enable`, `flush`, `destroy`. In this task `built` is true only for x86-64 Linux.
- `src/interp.zig`, three hunks: the field `jit: ?*jit.State = null`; `pub fn enableJit(it: *Interp, options: jit.Options) bool`; `reset` keeps the field and calls `jit.flush`, and `deinit` calls `jit.destroy`.
- `src/compact.zig`: one line calls `jit.flush` before the copy.
- `src/child.zig`: a new child of an interpreter with the JIT gets its own state with the same options. A child of an interpreter with no JIT has none.
- `src/vm.zig`: `Code` gets `jit: ?*anyopaque = null`, `jit_calls: u32 = 0`, and `jit_state: enum(u8) { untried, failed, ready } = .untried`. The parameter of `run` becomes `*Code`.
- `src/ztcl.zig`: `pub const jit = @import("jit.zig");`.
- `src/cli/main.zig`: the flags `--jit`, `--jit-threshold N`, `--jit-stats`.
- `tools/jit-perf.sh` (new), `bench/jit-baseline.tsv` (new).
- `tools/suite.sh`: the option `-j` adds `--jit --jit-threshold 0` to the runner and to the `ztclsh` script.

## Contracts

```zig
pub const Options = struct {
    /// Calls of a Code before it compiles. 0 compiles before the first run.
    threshold: u32 = 2,
    /// The most bytes for the executable region and all JIT data.
    mem_limit: usize = 16 << 20,
    tier2: bool = false,
    stress: u32 = 0,
};
```

- `enableJit` returns false and changes no state when `jit.built` is false. In this task it allocates the `State` from `it.counter.child`, outside the heap, and returns true.
- All memory of the JIT comes from `it.counter.child`. `Interp.memUsed` must not change when the JIT is on.
- `--jit-stats` writes one line to stderr at the end: `jit compiled=<n> failed=<n> code_bytes=<n> data_bytes=<n> fallbacks=<n> tier2=<n> exits=<n>`.
- `tools/jit-perf.sh --record` runs `perf stat -x, -e instructions:u` on `puts hi` and on each script of `bench/` and writes `bench/jit-baseline.tsv` (`name<TAB>instructions`). `--check off` runs the same scripts with no flag and fails when one count is more than 1 % above the baseline. `--check jit` runs with `--jit` and compares with the gates of `bench/jit-gates.tsv`, when that file exists.

## Acceptance

```sh
CAP zig build && CAP zig build test && CAP zig build test -Djit=false
CAP zig build wasm && node tools/wasm-smoke.mjs
CAP tools/jit-perf.sh --record        # record before the changes of this task, on the base commit
CAP tools/jit-perf.sh --check off     # after the changes
CAP zig-out/bin/ztcl --jit --jit-stats bench/sum.tcl    # 499999500000, and "jit compiled=0 ..."
CAP tools/suite.sh && CAP tools/suite.sh -j             # both: pass 19877
```

New unit tests: the default interpreter has no JIT state; `enableJit` and then `reset` keeps the state; a child of a JIT interpreter has a state and a child of a plain interpreter has none; `compact` works with the JIT on; `memUsed` is equal with the JIT on and off after the same script.

Gates: startup (`puts hi`) with no flag is at most 5000 instructions above the baseline. With `-Djit=false`, each count is at most 0.2 % above the baseline.

## Must not change

The capabilities and their tests. `compact` must still accept an interpreter with the JIT on: the JIT is not a capability.
