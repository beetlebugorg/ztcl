# Task 04: the trigger, the limits, and the embedder calls

## Goal

The collector runs by itself. A long loop holds a flat memory size.

## Files

- `src/heap.zig`: the trigger.
- `src/interp.zig`: `hold`, `release`, `addRoot`, `removeRoot`, the field `gc_on: bool`.
- `src/main.zig`: the flag `--gc off|on`.
- `src/wasm.zig`: no collection. No new export.
- `docs/embedding.md`, `docs/design.md`, `SECURITY.md`, `README.md` (Known limits), `CHANGELOG.md`.

## The trigger

- A collection starts inside an allocation when the bytes of the heap are at least `max(16 MiB, 2 * live)`. `live` is the count after the last collection.
- A collection also starts when an allocation brings the heap above `mem_limit`. If the heap is still above the limit after it, the next step check stops the script as today.
- The trigger reads only allocation counts. It reads no clock.
- With `gc_on` false, no collection starts. This is the mode of the exact memory limit.
- No collection starts while `compact` runs.

## The embedder calls

- `Interp.hold(v: Value) Allocator.Error!void` keeps a value and each block that it reaches. `Interp.release(v)` ends that.
- `Interp.addRoot(bytes: []const u8)` adds a range of embedder memory that can hold values. `removeRoot` ends that.
- New rule in `docs/embedding.md`: a `Value` from `eval` is valid until the next call into the interpreter. `hold` keeps it longer. The `roots` of `compact` work as before.
- The point proc code keeps its programs: check that `Interp.points` and each `Program` are reachable from the `Interp` struct or are a root.

## Acceptance

```sh
CAP zig build test
CAP tools/mem-flat.sh             # each row: the peak with 10 N passes is at most 1.10 times the peak with N. Exit code 0.
CAP tools/suite.sh                # pass 19877
CAP tools/suite.sh -a -r zig-out/bin/ztcl-suite    # pass 37383
CAP zig build bench               # same sum: true
CAP sh -c 'for f in bench/*.tcl; do perf stat -e instructions:u zig-out/bin/ztcl $f; done'
```

Gates:

- Each script of `bench/` uses at most 3 % more instructions than the baseline of task 01.
- A test runs one script two times with `--gc off --mem M --report` for a limit M that the script reaches. Both runs stop at the same step count.
- A test proves that a value under `hold` survives 100 collections, and that the same value with no `hold` is gone (the 0xDD fill) in a build with safety checks.

## Must not change

The output of a script that stays below its memory limit. The step counts.
