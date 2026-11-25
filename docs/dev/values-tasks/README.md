# Tasks for faster values

[The design](../values.md) has the profile and the reasons. Do the tasks in the order of their numbers. The order is the measured gain for each unit of risk. One task is one branch and one review.

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/dev/design.md`, and `docs/dev/values.md` first.
2. Run each build, test, and benchmark under the memory cap, one at a time. `CAP` means this prefix:

   ```sh
   systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 --
   ```

3. The common acceptance commands apply to each task:

   ```sh
   CAP zig build test
   CAP zig build test -Doptimize=ReleaseSafe
   CAP zig build test -Djit=false
   CAP tools/suite.sh                       # pass 19877, no file lower
   CAP tools/suite.sh -j
   CAP tools/jit-diff.sh
   CAP tools/thread-tests.sh
   CAP python3 -I tools/gc-fuzz.py -r zig-out/bin/ztcl
   CAP zig build json-fuzz
   CAP zig build wasm && node tools/wasm-smoke.mjs zig-out/lib/ztcl.wasm
   CAP python3 -I tools/bench-stdlib.py --only json
   ```

4. Speed gates are instruction counts of callgrind for one parse (`--toggle-collect=json.cmd.cmdParse`), and the best of 3 runs of `tools/bench-stdlib.py --only json`. No mode of `bench-stdlib.py` is slower than main by more than 3 %.
5. Memory gates are the heap bytes per JSON byte of `--report --gc off` after one parse. No file is higher than main.
6. The scripts of `bench/` keep their instruction counts within 1 % (`tools/jit-perf.sh --check off`).

## Tasks

| Task | Change | Gate |
|---|---|---|
| [01](01-numbers.md) | Eisel-Lemire on the parsed mantissa. Done: canada 30 % fewer instructions | canada: 25 % fewer instructions |
| [02](02-inline-push.md) | An inline push on the value stack. Done: 6 % to 9 % fewer instructions | 5 % fewer instructions on each file |
| [03](03-arena.md) | A cache of empty spans in the heap, then one block for each container and the arena | No mode slower in time, page faults equal to main or lower |
| [04](04-measure-dicts.md) | Measure dicts outside JSON | A table in `docs/dev/values.md` |
| [05](05-shapes.md) | Dict shapes, behind a flag | Memory of twitter and citm 15 % lower |
| [06](06-shape-users.md) | Shapes for TclOO, CSV, SQLite, `dict create` | Each user gives its measured gain |
