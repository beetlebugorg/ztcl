# A JIT compiler for ztcl

This page is the design of a compiler from the ztcl bytecode to machine code, and of the work that must come before it. Milestones 0, B, and 1 are in the source. [The results of milestones 0 and B](#results-of-milestones-0-and-b) and [the results of milestone 1](#results-of-milestone-1) are below. [The tasks](jit-tasks/README.md) give the order of the work, and [the review checklist](jit-review.md) is for the reviewer. [References](references/jit.md) lists the sources.

## Summary

- **Memory comes first.** A long-running script holds each value that it ever made, so two outside benchmarks stop at the memory limit. A JIT does not fix this. Milestone 0 gives memory back while a script runs. Milestone B makes four builtins faster. Both are work on the interpreter, and the JIT starts after them.
- **Two tiers above the interpreter.** Tier 1 is a template compiler: each bytecode instruction becomes a fixed piece of machine code, and the state at each instruction boundary equals the state of the interpreter. Tier 2 compiles hot loops of numbers with values in registers and exits to tier 1 when a guess fails.
- **The interpreter stays.** It is the fallback on each platform, the target of each exit, and the reference for each test.
- **Own assemblers.** ztcl has no dependency, so the project writes a small assembler for x86-64 and one for arm64.
- **Off by default.** The JIT is a build option and an embedder option. A script cannot turn it on. [The condition for a default of on](#the-condition-for-a-default-of-on) is in the security section.
- **Honest gains.** Tier 1 removes about two thirds of the instructions of an integer loop. It removes 10 % to 40 % for the benchmarks that allocation, hashing, or string work bound. Tier 2 helps only loops of numbers.

## The measured profile

All numbers in this section are from commit `0900a7e`, `ReleaseFast`, x86-64 Linux, Intel Core i7-6700K, measured on 2026-11-23 with `perf stat -e instructions:u` and `perf record`. The machine had other load. In that session `tools/bench.py` gave times about 1.8 times the times in the README for ztcl and for `tclsh`, and the ratio of the two stayed the same. Instruction counts do not change with the load, so each gate in this plan is an instruction count.

### Instruction counts

| Script | Instructions | Bytecode instructions run | Share of `vm.exec` |
|---|---|---|---|
| `puts hi` (startup) | 0.70 M | | |
| `sum.tcl` | 296.8 M | 9.00 M | 99.4 % |
| `fib.tcl` | 163.3 M | 2.55 M | 57.1 % |
| `nested.tcl` | 344.7 M | 10.02 M | 98.4 % |
| `strbuild.tcl` | 328.9 M | 5.50 M | 67.9 % |
| `foreach.tcl` | 211.5 M | 6.90 M | 99.2 % |
| `dict.tcl` | 282.7 M | 4.60 M | 49.6 % |
| `dictgrow.tcl` | 628.3 M | 5.20 M | 25.9 % |
| `readloop.tcl` | 213.9 M | 4.00 M | 55.9 % |

The interpreter uses about 33 machine instructions for one bytecode instruction in `sum.tcl`, `nested.tcl`, and `foreach.tcl`. The handler of `jf_vv` alone has about 45 instructions on its integer path. The dispatch, the decode of the operands, the two checks of each cell tag, and the spills of optional values make this cost.

### Where the time goes

| Script | Time outside `vm.exec` | What bounds it |
|---|---|---|
| `sum.tcl` | none above 0.3 % | The bytecode loop: 9 instructions for each pass. |
| `fib.tcl` | `callProc` 30.7 %, `vm.run` 5.1 %, the frame list 3.8 %, `resolve` 2.4 % | The proc call: the frame, the cells of the parameters, and the entry of `run`. |
| `nested.tcl` | `memcpy` 0.8 % | The bytecode loop and the append to the list. |
| `strbuild.tcl` | `appendStr` 19.1 %, `memcpy` 12.3 % | String work. The append code inside `vm.exec` is also string work. |
| `foreach.tcl` | none above 0.3 % | The bytecode loop: 6 instructions for each item. |
| `dict.tcl` | `dict.lookup` 9.3 %, Wyhash 8.4 %, `cmdDict` 7.5 %, `expr.intOp` 7.5 %, `hashKey` 6.7 %, `probe` 6.5 %, `getIn` 3.9 % | Hashing and the lookup. |
| `dictgrow.tcl` | `concatValues` 10.8 %, Wyhash 7.6 %, `cmdDict` 7.1 %, `probe` 6.9 %, `lookup` 5.9 %, the arena 5.8 %, `findVar` 5.7 %, `memcpy` 3.9 % | Allocation, hashing, and string work. |
| `readloop.tcl` | `mem.eql` 30.7 %, `readList` 7.3 %, `expr.intOp` 5.6 % | The compare of the 599-byte string with its copy in the list cache. |

### The cost of one statement

Each row is one loop of one million passes in a proc. The first row is the empty loop.

| Body of `for {set i 0} {$i < $n} {incr i} {...}` | Instructions for each pass |
|---|---|
| empty | 169 |
| `set s [expr {$s + $i}]` | 296 |
| `set s [expr {$i % 100}]` | 301 |
| `incr s $x` | 248 |
| `set s [llength $l]` | 265 |
| `lappend row [expr {$i * $i}]` | 341 |
| `append s "x$i,"` | 623 |
| `dict incr d [expr {$i % 100}]` | 554 |
| `incr s [dict get $d [expr {$i % 100}]]` | 856 |
| `set s [f $i]` with `proc f {x} {return $x}` | 733 |
| `dict set d key$i $i` | 1934 |

### A model of the compiled loop

A hand-written model of the machine code for the loop of `sum.tcl` gives a measured number for both tiers. The model uses the data layout of the `ReleaseFast` build: the cell pointer in the frame entry, the two tag checks, the step limit, the memory limit, and the epoch check. It is not in the repository.

| Code for the loop of `sum.tcl` | Instructions | Cycles in the same session |
|---|---|---|
| The interpreter | 296.8 M | 171.1 M |
| Tier 1 form: one template for each bytecode, values in cells | 94.2 M | 53.4 M |
| Tier 2 form: `i`, `s`, and `n` in registers, one step check for each pass | 10.2 M | 6.7 M |

### What each tier can remove

The numbers are ratios of instruction counts against the interpreter of today. Only the `sum.tcl` rows come from a measured model. The other rows are estimates from the statement costs above.

| Script | Tier 1, milestone 1 | Tier 1, milestone 2 | Tier 2 | Bound by |
|---|---|---|---|---|
| `sum.tcl` | 2.7 to 3.1 | the same | about 20 | The bytecode. |
| `fib.tcl` | 1.3 to 1.5 | 1.45 to 1.65 | no more gain | The proc frame. |
| `nested.tcl` | 2.1 to 2.5 | 2.4 to 2.8 | 3 to 4 | The append to the list. |
| `foreach.tcl` | 1.9 to 2.3 | 2.4 to 2.9 | about 4 | The bytecode. |
| `strbuild.tcl` | 1.2 to 1.4 | the same | no more gain | String work. |
| `dict.tcl` | 1.25 to 1.45 | the same | no more gain | Hashing. |
| `dictgrow.tcl` | 1.1 to 1.2 | the same | no more gain | Allocation, hashing, and string work. |
| `readloop.tcl` | 1.3 to 1.5 | 1.5 to 1.7 | no more gain | The list cache compare. |

This plan promises no gain for the work that a helper function does: the hash of a key, the growth of a string, the copy of a list buffer, the arena, and the frame of a proc call. For `dictgrow.tcl`, `dict.tcl`, `strbuild.tcl`, and `readloop.tcl`, a change to that code has more effect than a JIT. The roadmap has such items: a cached list form for a string value, and cheaper proc frames. They are separate work.

### The outside benchmarks

The Tcl programs of [kostya/benchmarks](https://github.com/kostya/benchmarks) (MIT), at commit `5bc68b3705`, are an outside gate: `brainfuck/bf.tcl` and `brainfuck/bf_oo.tcl` with `bench.b`, and `base64/test.tcl`. The repository has no copy of them. `matmul` needs the tcllib package `math::linearalgebra`, which ztcl does not have, so it is not a gate.

A first run on the busy machine, against `tclsh` 8.6.16, with each capability on, a step limit of 10^11, and a memory limit of 6 GiB:

| Program | ztcl | `tclsh` 8.6.16 |
|---|---|---|
| `bf.tcl bench.b` | Stops after 11 s with `the script used too much memory`. | 344 s |
| `bf_oo.tcl bench.b` | Stops with the same error. | Not done after 420 s. |
| `base64/test.tcl`, encode | 4.50 s | 3.27 s |
| `base64/test.tcl`, decode | 9.29 s | 5.75 s |

With the default limit of 2 GiB, `base64/test.tcl` also stops with the memory error.

**The cause is the arena.** All memory of the interpreter comes from one arena, and the arena frees memory only at `compact`, `reset`, or `deinit`. `compact` cannot run while a script runs. So each value that a loop makes stays until the script ends. `tclsh` counts the references of each value and frees a value at its last use. These loops of 200 000 to 1 million passes show the growth and the cost of the commands that the programs use:

| Body of one pass | ztcl memory for each pass | ztcl instructions | `tclsh` instructions | `tclsh` memory |
|---|---|---|---|---|
| `lset tape 3 5` on a list of 100 items | 2460 bytes | 1420 | 750 | flat |
| `lassign [f $tape $pos] tape pos`, where `f` returns `[list $tape $pos]` | 127 bytes | | | flat |
| `lassign $x op val` | 30 bytes | 980 | 740 | flat |
| `switch -exact -- $op {INC {...} MOVE {...}}` | 128 bytes | 2140 | 660 | flat |
| A method call `$o p 3` | 125 bytes | 5200 | 3900 | flat |
| `binary encode base64` of 131 072 bytes | 242 KiB | 6.9 M | 4.3 M | flat |
| `binary decode base64` of 174 764 bytes | 168 KiB | 16.1 M | 4.7 M | flat |

`lset` copies the whole list at each call, because no code can prove that the cell is the one holder of the buffer. `binary encode base64` runs 8192 times in the benchmark, so the results alone are 1.9 GiB.

**Where each gain comes from.** The JIT removes the dispatch of bytecode. In `bf.tcl`, each step of the inner loop is `lassign`, `switch`, `lset`, and `lindex`. Three of them are general commands today, so the JIT has little to remove.

| Program | Milestone 0: memory | Milestone B: builtins | The JIT |
|---|---|---|---|
| `bf.tcl`, `bf_oo.tcl` | The program ends with the correct checksum. Without this, each other gain is zero. | The largest gain. `switch`, `lassign`, and `lset` use about 4500 instructions for one step against about 1800 in `tclsh`. As bytecode with an in-place `lset`, the estimate is about 400. | An estimate of 1.5 to 2 times on top, after the commands are bytecode. |
| `base64/test.tcl` | The program ends at the default limit. | All of the gain: the two codec loops. Decode uses 3.4 times the instructions of `tclsh`. | None. The script loop has 16 384 passes. |

The estimates of this table come from the loops above. No one measured them on the whole programs.

### Point procs

The vector path of a point proc is about 15 ns for each point. It pays the dispatch one time for each block of 1024 points: the fuzzy skin program has 16 operations for each block. The loops of the operations are SIMD code from the Zig compiler. A JIT has no dispatch cost to remove there. This plan does not compile vector programs. The author did not measure the share of `noise3` on the vector path.

The slow path of a point proc is a normal proc, so tier 1 compiles it. Rule 6 of AGENTS.md stays: tier 1 calls the same functions as the interpreter for each operation on a double, so the bits stay equal.

## Milestone 0: memory that a script no longer uses

### The decision

ztcl replaces the arena with a heap that has a mark-and-sweep collector. The collector does not move a block, and it finds pointers conservatively: each aligned word in a root or in a live block that has the address of a heap block keeps that block.

| Choice | Why not |
|---|---|
| Count references, as `tclsh` does | A `Value` is a plain 24-byte copy at about 440 allocation sites and each place that stores a value. Each copy needs a count change. One missed change is a use after free. |
| Run `compact` inside a script | `compact` moves each block, so it must know each pointer exactly. Values in the native frames of Zig code have no map. |
| A region for each proc call, with a copy of each value that leaves it | Each store into a longer-lived place needs the copy: a variable, a list buffer, an array, a cache. One missed store is a use after free. |
| A conservative collector that does not move (the choice) | A missed root is still a use after free, but the roots are few: the interpreter struct, the native stack, the registers, and the coroutine stacks. A number that looks like an address keeps a dead block. That costs memory, never safety. |

### The parts

- **The heap** (`src/heap.zig`). Size classes in pages, a mark bit for each block, large blocks of whole pages, and a table from an address to its block. A pointer into the middle of a block keeps the block, because a string is often a part of a buffer. The heap has the `Allocator` interface, so `it.alloc()` stays as it is.
- **The roots.** See [the limits section of the design](design.md). A native build scans the `Interp` structs, the native stacks, the registers, and the embedder ranges. WebAssembly uses precise roots at bytecode safe points.
- **The trigger.** A collection starts at a safe point, when the heap holds two times the bytes that were live after the last collection, and at least 16 MiB. After a collection that freed under half of the heap, the factor is four. The numbers are a function of the allocation history alone.
- **The sweep.** A dead block goes to the free list of its size class. A page with no live block goes back to the allocator of the embedder.
- **`compact`, `reset`, `deinit`.** They stay. `reset` and `deinit` free the heap in one step. `compact` copies the live data to a new heap as today.
- **A stress mode.** `--gc-stress N` collects at each Nth allocation. The unit tests and the suite run in this mode, in a build with safety checks, and a freed block is filled with a pattern. This mode finds a missed root.
- **`lset` in place.** A cell can own a list, as a cell can own a dict today. Then `lset` writes to the buffer and makes no garbage. This removes the largest source of garbage in `bf.tcl` and the copy of the list.

### What changes for the embedder and for the limits

- **A value from `eval`.** Today a `Value` that `eval` returns is valid until `compact` or `reset`. With the collector, it is valid until the next call into the interpreter. A new call `Interp.hold(v)` keeps a value longer, and `Interp.release` ends that. This is an API change for zslice.
- **The memory limit.** `mem_limit` bounds the bytes of the heap. A script that stays below the limit gives the same output on each run. The exact place of the memory error can differ between two runs, because a word on the native stack can look like an address. Today that place is exact. `--gc off` turns the collector off, and the limit is then exact as today. The differential tests of the JIT use `--gc off` for the memory count.
- **Speed.** An allocation from a size class costs more than a bump of the arena. The gate is at most 3 % more instructions for each of the eight benchmarks.
- **The JIT.** A collection starts only at a safe point. The collector scans the value stack and the cells, where tier 1 keeps each value. Tier 2 keeps only integers and doubles in registers. The rule for each later change is: no pointer to a heap block is only in a register of machine code across a helper call. The data of the JIT is outside the heap and holds no pointer that keeps a block.

### The gates of milestone 0

| Gate | Limit |
|---|---|
| A loop of each row of the table above, with N passes and with 10 N passes | The peak of `memUsed` differs by at most 10 %. |
| `bf.tcl bench.b`, `bf_oo.tcl bench.b`, `base64/test.tcl` at the default limit of 2 GiB | Each one ends. The output equals the output of `tclsh` 8.6.16, with the two time fields of `base64` removed. The peak of `memUsed` is at most 64 MiB. |
| The eight benchmarks | At most 3 % more instructions than today. |
| The unit tests and the suite with `--gc-stress 1` on a small set and `--gc-stress 64` on all files | The counts of today, and no safety check fails. |

### Results of milestones 0 and B

Measured on commit `bbdc5bf`, `ReleaseFast`, x86-64 Linux, against `tclsh` 8.6.16 in the same session. Each program ran one time at the default limit of 2 GiB, and each output equals the output of `tclsh`.

| Program | ztcl instructions | `tclsh` instructions | Ratio | Gate after milestone B | Peak RSS of ztcl |
|---|---|---|---|---|---|
| `base64/test.tcl` | 50.7 G | 72.4 G | 0.70 | at most 1.0: pass | 19.0 MB |
| `bf.tcl bench.b` | 1311 G | 2774 G | 0.47 | at most 0.5: pass | 20.1 MB |
| `bf_oo.tcl bench.b` | 7429 G | 5372 G | 1.38 | at most 0.5: **fail** | 22.4 MB |

The cause of the `bf_oo.tcl` result was not profiled. The two `bf` gates stay provisional until the user sets them.

## Milestone B: the builtins of the outside benchmarks

| Work | Today | Target |
|---|---|---|
| `switch -exact` with literal patterns and bodies, as bytecode | 2140 instructions for one pass, 128 bytes | At most the count of `tclsh` (660), no allocation |
| `lassign` with plain variable names, as bytecode | 980 | At most 740, no allocation |
| `lset var index value` with one index, as bytecode, in place for an owned list | 1420 | At most 750, no allocation |
| `binary encode base64` and `binary decode base64` | 6.9 M and 16.1 M for 131 072 bytes | At most the counts of `tclsh` (4.3 M and 4.7 M) |

The gate of the whole programs is a ratio of instruction counts against `tclsh` 8.6.16 in the same session, with the same output:

| Program | After milestone 0 | After milestone B | After milestone 2 of the JIT |
|---|---|---|---|
| `base64/test.tcl` | ends | at most 1.0 | at most 1.0 |
| `bf.tcl bench.b` | ends | at most 0.5 | at most 0.35 |
| `bf_oo.tcl bench.b` | ends | at most 0.5 | at most 0.35 |

The two `bf` ratios are provisional. Task 06 measures the first full run, and the user sets the final numbers then. A full run of `bench.b` needs minutes, so this gate runs one time at the end of each milestone.

## Results of milestone 1

Tier 1 runs on x86-64 Linux behind `-Djit` and `--jit`. Measured on the commit of task 18, `ReleaseFast`, with `perf stat -e instructions:u` of the whole process. The baseline is the commit before task 10.

| Script | Interpreter (baseline) | `--jit` | Gate | Result |
|---|---|---|---|---|
| `sum.tcl` | 284.8 M | 90.9 M | 105.6 M (110 M scaled by 0.960) | pass |
| `fib.tcl` | 164.8 M | 142.0 M | 125 M | fail |
| `nested.tcl` | 337.6 M | 173.3 M | 165 M | fail |
| `strbuild.tcl` | 324.5 M | 252.6 M | 270 M | pass |
| `foreach.tcl` | 209.9 M | 148.4 M | 110 M | fail |
| `dict.tcl` | 281.4 M | 233.9 M | 230 M | fail |
| `dictgrow.tcl` | 644.2 M | 578.2 M | 580 M | pass |
| `readloop.tcl` | 209.9 M | 175.3 M | 165 M | fail |

The baseline of `sum.tcl` was 4.0 % below the table "Instruction counts", so its gate is scaled. Each other baseline is within 3 % of that table.

The causes of the five failures, from `perf record`:

- `foreach.tcl`: `foreach_next` is a helper call. The helper uses about 90 instructions for each item. An inline `foreach_next` is in milestone 2.
- `nested.tcl`: `lappend` is a helper call of about 85 instructions for each pass. An inline `lappend` is in milestone 2.
- `readloop.tcl` and `dict.tcl`: `%` goes to the helper of `bin_vi` or `bin_vv`, and `llength`, `lindex`, and `dict` are helper calls. An inline `%` is in milestone 2.
- `fib.tcl`: the proc frame. `vm.run`, `jit.prepare`, `jit.enter`, the prologue, and the epilogue use about 70 instructions for each call more than `exec`.

Other measured costs:

| Cost | Limit | Measured |
|---|---|---|
| Code size of tier 1, mean over the procs of the eight benchmarks | 96 bytes for one instruction | 69 bytes (34 884 bytes for 503 instructions) |
| Compile time of tier 1 | 400 instructions for one bytecode instruction | about 2 600: 104 000 instructions for each proc of a test with 300 procs of 40 bytecode instructions each (the loop of `sum.tcl`). The encoder of `x64.zig` and the allocations of the labels cost the most. **fail** |
| Native stack of 500 proc call levels | at most the interpreter | 1 598 208 bytes with the JIT, 3 449 904 without |
| Interpreter counts with the JIT in the build and off | at most 1 % above the baseline | at most 0.3 % above, except `foreach.tcl` at 1.9 % above |
| Startup (`puts hi`), JIT off | 5000 instructions above the baseline | 141 above |

The outside programs with `tools/kostya.sh --jit`, against `tclsh` 8.6.16 in the same session. Each output equals the output of `tclsh`.

| Program | ztcl `--jit` instructions | `tclsh` instructions | Ratio | Ratio without the JIT (milestone B) |
|---|---|---|---|---|
| `base64/test.tcl` | 50.7 G | 72.4 G | 0.70 | 0.70 |
| `bf.tcl bench.b` | 1168 G | 2771 G | 0.42 | 0.47 |
| `bf_oo.tcl bench.b` | 7313 G | 5363 G | 1.36 | 1.38 |

The hot work of `bf_oo.tcl` is method calls, which go through helpers and the frame of a proc call.

The tests of milestone 1:

- `tools/jit-diff.sh`: 148 runs of 54 scripts of `tests/jit/`, 12 of `tests/mem/`, and 8 of `bench/` in modes 2 and 3 equal mode 1, also with `-x "--gc-stress 1"`. The step limit sweep compared 682 step limits. The interpreter output of 53 scripts equals the output of tclsh 8.6.16. `tests/jit/errors.tcl` has no `.out` file, because the `errorInfo` of ztcl has more lines than the one of tclsh.
- `tools/suite.sh -j`: 19 877 on the 37 core files and 37 383 on all 152 files with the suite runner, each file equal to the run without `-j`. A `ReleaseSafe` suite runner with `-g 64` gives 20 644 with and without `-j`, each file equal.
- `tools/gc-fuzz.py -j -g 1` with a `ReleaseSafe` runner: 300 programs, no crash. One program differed because the JIT uses less native stack for one proc call level, so a recursion with no end stopped at a deeper level. The semantics table above names this case. One program differed with and without the collector at the memory limit, also without the JIT. The tool now counts the first case and does not compare it.
- Three fixes were reversed one at a time, and a unit test failed each time: the overflow check of `+`, `-`, and `*`, the check of the integer tag of a cell, and the restore of the step count before the slow path of the memory check.

Task 15 moved each handler of `vm.exec` to a function. The guard and `foreach_next` stay in two parts in `exec`: `guardJumps` and `step`, and `foreachAdvance` with no check of the kinds. The joined forms made `sum.tcl` 6 % and `foreach.tcl` 5 % longer. The remaining 1.9 % of `foreach.tcl` comes from the code layout of `exec`: a copy of the old handler made `sum.tcl` and `nested.tcl` 2 % longer.

## Results of milestone 2

Measured on 2026-11-24 on the commit of task 35, `ReleaseFast`, x86-64 Linux, with `perf stat -e instructions:u` of the whole process. Tasks 19 to 23 (the fuzzers, the stress modes of tier 1, the hardening tests, and named code) are on another branch and are not in these numbers.

| Script | Interpreter (baseline) | `--jit`, milestone 1 | `--jit`, milestone 2 | Gate | Result |
|---|---|---|---|---|---|
| `sum.tcl` | 284.8 M | 90.9 M | 90.9 M | 105.6 M | pass |
| `fib.tcl` | 164.8 M | 142.0 M | 136.1 M | 112 M | fail |
| `nested.tcl` | 337.6 M | 173.3 M | 123.8 M | 135 M | pass |
| `strbuild.tcl` | 324.5 M | 252.6 M | 252.6 M | 270 M | pass |
| `foreach.tcl` | 209.9 M | 148.4 M | 80.4 M | 88 M | pass |
| `dict.tcl` | 281.4 M | 233.9 M | 194.9 M | 215 M | pass |
| `dictgrow.tcl` | 644.2 M | 578.2 M | 572.4 M | 580 M | pass |
| `readloop.tcl` | 209.9 M | 175.3 M | 154.7 M | 150 M | fail |

The causes of the two failures, from `perf record`:

- `fib.tcl`: the proc frame. `callProc` with `runProc` (the frame, the cells of the parameters, and the list of free frames) and the helper of `invoke` are about half of the instructions, and `vm.run` is about 14 %. The direct call of task 25 removed the second resolve of the site. A cheaper frame is work on the interpreter. The count was 133.5 M after task 25. The two fields of the context that tier 2 added (`counters`, `func`) raised it to 136.1 M.
- `readloop.tcl`: the script reads a string as a list. `mem.eql` in the list cache is 44 % of the instructions, and the inline paths of `llength` and `lindex` serve only a list value.

Other costs:

| Cost | Limit | Measured |
|---|---|---|
| Compile time of tier 1 | 400 instructions for one bytecode instruction | about 2 570: 102 700 instructions for each of 300 procs like the loop of `sum.tcl`. `Asm.op` is 23 % of them, `jit.compileCode` 13 %, `memcpy` 10 %. **fail** |
| Interpreter counts with the JIT in the build and off | at most 1 % above the baseline | at most 0.9 % above, except `foreach.tcl` at 1.9 % above. A build with `-Djit=false` gives the same count for `foreach.tcl`: 213.8 M. The cost comes from the handler refactor of task 15, and the JIT in the build adds none. |

`dictgrow.tcl` with the JIT off moved between 645.6 M and 658.0 M between builds. With `--gc off` the counts of the builds are equal within 0.01 %, so the change is the work of the collector, which depends on the words that the native stack holds.

The outside programs with `tools/kostya.sh --jit` on the commit of task 25, against `tclsh` 8.6.16 in the same session. Each output equals the output of `tclsh`.

| Program | Ratio, milestone 1 | Ratio, milestone 2 | Gate |
|---|---|---|---|
| `bf.tcl bench.b` | 0.42 | 0.38 | 0.35 (provisional): fail |
| `bf_oo.tcl bench.b` | 1.36 | 1.33 | 0.35 (provisional): fail |
| `base64/test.tcl` | 0.70 | 0.70 | 1.0: pass |

`bf.tcl` gained from the inline `lindex`, `str_eq_jump` (the cases of `switch`), and `lset_drop` of task 24. `bf_oo.tcl` spends its time in method calls, which go through `callMethod` and `runProc`.

## Results of tier 2

Tier 2 (tasks 33 to 37) compiles a loop with integers and doubles in registers, and with calls of the helpers of tier 1. Measured on 2026-11-24 after task 38, `ReleaseFast`, x86-64 Linux, with `perf stat -e instructions:u` of the whole process. Each count of tier 2 is at or below the count of tier 1.

| Script | Interpreter | `--jit` | `--jit --jit-tier2` | Gate of tier 2 | Result |
|---|---|---|---|---|---|
| `sum.tcl` | 283.8 M | 90.9 M | 15.0 M | 16 M | pass |
| `nested.tcl` | 337.6 M | 123.7 M | 55.4 M | 100 M | pass |
| `foreach.tcl` | 213.8 M | 80.4 M | 40.6 M | 45 M | pass |
| `dsum.tcl` | 700.8 M | 557.9 M | 16.6 M | 16.9 M | pass |
| `dict.tcl` | 281.0 M | 194.9 M | 188.5 M | 194.9 M (tier 1) | pass |
| `readloop.tcl` | 208.9 M | 154.7 M | 146.9 M | 154.7 M (tier 1) | pass |
| `dictgrow.tcl` | 645.6 M | 572.4 M | 570.3 M | 572.4 M (tier 1) | pass |
| `strbuild.tcl` | 324.0 M | 252.6 M | 243.1 M | | |
| `fib.tcl` | 165.1 M | 134.2 M | 134.2 M | | |

The gates of tier 1 in `bench/jit-gates.tsv` did not change: `fib.tcl` (134.2 M, gate 112 M) and `readloop.tcl` (154.7 M, gate 150 M) fail for the causes above.

`dsum.tcl` sets `x` with `expr`, because a literal word is a string, and a string operand goes to a helper in each pass. The model of task 32 for its loop is 14 instructions for one pass. Tier 2 uses about 16: the joined step check, the compare of the loop, `mulsd` with a constant register, `addsd` into the register of `s` with a NaN check, and the `incr`.

The first build of tasks 36 and 37 used more instructions with tier 2 than with tier 1 on `dict.tcl` (251.0 M), `readloop.tcl` (192.6 M), and `dictgrow.tcl` (589.1 M). The causes, from `perf record`:

- Integer `/` and `%` were helper calls in tier 2 and inline in tier 1.
- `invoke` called the helper that resolves the name. Tier 1 checks the cached command site inline.
- The plan gives the kind `any` to the result of a helper, so `incr s [dict get ...]` and the jumps on such a value were helper calls in tier 2. Tier 1 checks the tag at run time.
- Each call wrote the slot registers to their cells and loaded them again. A helper that runs no script now keeps the integer slot registers on the native stack.
- `lindex` and `llength` of a list value were helper calls in tier 2.
- A loop that runs a few passes for each entry pays the entry block, the exit, and the calls of `tier_up` and `resume_at` at each entry. A loop with calls now counts its passes at its back jump, and after 64 entries a loop with fewer than 16 passes for each entry runs in tier 1 only. The count costs one instruction for each pass, so `nested.tcl` and `foreach.tcl` went from 52.4 M and 37.3 M to 55.4 M and 40.6 M.

`bench/jit-gates2.tsv` has gates for the three scripts at the count of tier 1.

Wall time, best of 5 runs, on a machine that another job shared, so each number is noisy by a few milliseconds:

| Script | Interpreter | `--jit` | `--jit --jit-tier2` |
|---|---|---|---|
| `sum.tcl` | 20 ms | 9 ms | 3 ms |
| `dsum.tcl` | 49 ms | 43 ms | 3 ms |
| `nested.tcl` | 36 ms | 25 ms | 19 ms |
| `foreach.tcl` | 17 ms | 10 ms | 7 ms |
| `dict.tcl` | 23 ms | 21 ms | 19 ms |
| `readloop.tcl` | 17 ms | 16 ms | 15 ms |
| `dictgrow.tcl` | 73 ms | 69 ms | 68 ms |
| `strbuild.tcl` | 27 ms | 22 ms | 22 ms |
| `fib.tcl` | 16 ms | 14 ms | 14 ms |

The outside programs with `tools/kostya.sh --jit` and `--jit-tier2`, against `tclsh` 8.6.16 in the same session, on the build before the count of passes. Each output equals the output of `tclsh`.

| Program | `--jit` | `--jit --jit-tier2` | Ratio with tier 2 |
|---|---|---|---|
| `base64/test.tcl` | 50.7 G | 50.7 G | 0.70 |
| `bf.tcl bench.b` | 1044.1 G | 1059.2 G | 0.38 |
| `bf_oo.tcl bench.b` | 7137.7 G | 7161.9 G | 1.34 |

Tier 2 used 1.4 % more on `bf.tcl` and 0.3 % more on `bf_oo.tcl`. The count of passes is the fix: on a smaller program of `bf.tcl` (`bfm2`, 214.0 M with tier 1), tier 2 went from 228.4 M to 215.7 M. The outside programs did not run again after it, so the table has the counts before it.

The tests of tier 2:

- `zig build test` passes in Debug, in `ReleaseSafe`, and with `-Djit=false`. `zig build bench` gives `same sum: true` for each row.
- `tools/jit-diff.sh -t`: 154 runs of the scripts of `tests/jit/`, `tests/mem/`, and `bench/`, and 682 step limits of the sweep, equal to the interpreter. The same with `-x "--jit-stress 32"` and with `-x "--gc-stress 1"`, and without `-t`.
- `tools/suite.sh -a -J` and `tools/suite.sh -a -j`: 37 383 on all 152 files, each file equal.
- `tools/gc-fuzz.py -j -T -g 1` with a `ReleaseSafe` runner: 300 programs, none differ. One run reached the time limit, and one stopped at another depth at the nesting limit, as in milestone 1.
- One fix of each task was reversed, and a test failed each time. Task 36: the check of the cell tag in the entry block (the new test with a link whose bytes look like an integer), the checks after a call (two tests), and the write of the slots before a call (a test then loops until it is stopped). Task 37: the NaN check of a result, the NaN check of the entry block, the tag check of `incr_value` on a value from a helper, the write of the kept slots at an exit after a helper that runs no script, and the register of the result of `to_bool` (`tests/jit/tier2_calls.tcl` with `tools/jit-diff.sh`: the unit test does not find it in a Debug build). Task 38: the count of the steps of a part.
- The fuzzer of task 19 (`zig build jit-fuzz`) is on the branch of tasks 19 to 23, so it did not run here, and its double constants of task 37 are not in it.
- The suite runs, the fuzzer, and the tests in `ReleaseSafe` and with `-Djit=false` ran on the build before the count of passes. After it, `zig build test` in Debug and `tools/jit-diff.sh -t` with and without `-x "--jit-stress 32"` ran again and passed.

Tier 2 differs from the design above in these points:

- The exits are code. Each exit writes the slot registers to their cells and the stack places to the value stack, gives back the steps of its part, and calls `resume_at`, which gives the address of the tier 1 code of the exit address after the checks of `jit.enter`. No exit record is in JIT data, and no `jit.deopt` reads one.
- A slot of the kind `int` or `double` is in a register for the whole loop: at most five integers and four doubles. A slot of the kind `any` stays in its cell. A stack place is in a register when its kind is `int` or `double`, and in the value stack when its kind is `any`. A loop that needs more registers stays in tier 1.
- `r12`, the register of the helper table, holds a stack place or a constant inside a loop. Each call and each exit loads it again from the context.
- A `guard` is no branch in tier 2. The entry block and each call that can run a script check the epoch, so each `guard` of the loop passes.
- A NaN result of an operation on doubles is valid in Tcl. Its check exits after the instruction with the result in its place, so no register holds a NaN and the interpreter raises the error at the next use.
- A compiled loop enters tier 2 again at the next pass of its head in tier 1. A loop that does not compile runs in tier 1 with no more calls of `tier_up`.
- `--jit-stress 32` fails each guard of tier 2 on the schedule 3, 7, 13, and the same schedule forces exits after calls. `tools/suite.sh -J` runs the suite with tier 2 at a loop count of 2, `tools/jit-diff.sh -t` adds tier 2 to the JIT modes, `tools/gc-fuzz.py -j -T` adds tier 2 to the fuzzer, and `tools/kostya.sh --jit-tier2` runs the outside programs with tier 2.
- On x86-64, tier 2 uses `rsi`, `rdi`, and `xmm6` to `xmm15` for places and constants. They are callee-saved on Windows.

### Tier 2 on arm64: the hand-off (task 38)

The arm64 code of tier 2 is not written. This branch has the parts that do not depend on the instruction set, and the session on the Mac builds the rest.

What is in place:

- `src/jit/tier2.zig` makes the plan of a loop: the kinds of each slot and each stack place, the parts, and the kinds after each instruction.
- `src/jit/tier2_lower.zig` reads the plan with no machine code. `eligible` reads the register counts of a backend from a `Budget`, and `a64_budget` has the counts of the registers below. `slotClass`, `checkAt`, `stepsLeft`, `needsFix`, `nanFree`, and `branchTarget` give the class of each slot, the place of each step check, the steps that an exit gives back, the edges that write a place to the value stack, the double results that need no NaN check, and the second successor of a helper call.
- The tests named `tier 2 layer: ...` in `src/jit/tests.zig` check these facts with no machine code. Each test named `tier 2: ...` compares a script with the interpreter, so it is the acceptance test of each backend.
- `src/jit/tier2_x64.zig` is the reference for each rule below.

What the Mac session builds:

1. `src/jit/tier2_a64.zig` with the `assemble` and `eligible` of `tier2_x64.zig`, and a choice of the backend in `jit.compileLoop`. `jit.backend` and `build.zig` then turn tier 2 on for arm64.
2. The registers of `a64_budget`: `x9` to `x13` for integer slots, `x3` to `x8` for integer places and constants, `d16` to `d19` for double slots, `d22` to `d31` for double places and constants. `x14`, `x15`, `d20`, and `d21` are scratch. Each one is caller-saved, so a call writes and loads them as on x86-64. The code never uses `x18` or `d8` to `d15`.
3. The entry block: for each slot in a register, the cell tag `.val`, the value tag, the load, and for a double a NaN check (`fcmp d, d` and `b.vs`). Then the epoch and the memory count.
4. One joined step check at `checkAt` of each part. An exit writes each place in a register and each slot that the loop writes, adds `stepsLeft` back, and goes to one shared block that calls `resume_at`.
5. Integers: `adds`, `subs`, and `b.vs` for the overflow check, the multiply check of task 27, and `sdiv` with `msub` for `/` and `%`, with an exit for a divisor of 0 or -1 and the rounding down of Tcl. The operation writes a scratch register, and the slot register changes after the check.
6. Doubles: `fadd`, `fsub`, `fmul`, `fdiv`, `scvtf` for an integer operand, and `fcmp` with the conditions `mi`, `ls`, `gt`, `ge`, `eq`, `ne` for the six compares. No `fmadd`. A result that `nanFree` does not clear gets `fcmp` with itself and `b.vs` to an exit after the instruction, with the result in its place.
7. Calls: write the slots and the places, call the helper of tier 1 (for `invoke`, the inline check of the command site and `call_cached`), the error stub, then for each successor the epoch check, the memory check, and the loads of the slots with their checks. After a helper that `tier2.runsNoScript` lists, the integer slot registers can stay on the stack, and each exit after the call writes them first.
8. The inline paths of `lappend`, `foreach_next`, `load` and `store` of a slot in its cell, and `incr_value` and the jumps on a value in the value stack, each with the helper as the slow path.
9. The instruction cache flush of the tier 2 code before its first run.

Then run the acceptance list of task 38 on each arm64 target, and check that no script of `bench/` uses more time with tier 2 than with tier 1.

On x86-64 Windows, `rsi`, `rdi`, and `xmm6` to `xmm15` are callee-saved. `tier2_x64.zig` uses them for places and constants, so that port must save them or leave them out of `extra_regs` and `extra_xregs`.

## The tier 2 model and census (task 32)

`tools/jit-model/run.sh` assembles hand-written tier 2 forms of four loops (`tools/jit-model/model.s`) and counts one pass of each with `perf stat -e instructions:u`. Each form has the joined step check of its part, the guards, and the overflow checks of the rules of tier 2. Measured on 2026-11-24 on the commit of task 32, x86-64 Linux:

| Loop | Instructions for one pass | Model of the script | Tier 1 (`--jit`) | Gate |
|---|---|---|---|---|
| `sum.tcl` | 14 | 14.7 M | 90.9 M | 16 M |
| `nested.tcl`, the inner loop with the inline `lappend` | 24 | 24.7 M | 123.7 M | 100 M |
| `foreach.tcl`, `foreach` with a guard of the item tag | 20 | 23.1 M | 80.4 M | 45 M |
| `dsum.tcl`, `set s [expr {$s + $x * 0.5}]` | 14 | 14.7 M | 557.9 M (task 37) | 16.9 M (the model plus 15 %) |

The model of a script is the startup count (`puts hi`, 0.72 M) plus the passes of its hot loops times the count of one pass. The model of `sum.tcl` is 14.7 M. The earlier model gave 10.2 M. This form writes each result to a scratch register first and moves it to the slot register after the overflow check, as task 34 asks. The models of `nested.tcl` and `foreach.tcl` have the inline paths of tier 1 in the loop and no call out, and `nested.tcl` uses an indexed address that the assembler of the JIT does not have. So they are a lower bound, and the gates of those two stay at the provisional numbers.

`zig build jit-census -- FILE...` runs each script, compiles the body of each proc, and puts each loop in a class: only the integer set of tier 2 (int), the integer set with helper calls (calls), or not eligible (no: an inner loop or a `ret`). Results:

| Scripts | int | calls | no | First instruction outside the integer set |
|---|---|---|---|---|
| `bench/*.tcl` | 1 | 9 | 2 | `push` 4, `foreach_next` 2, `lappend` 2, `dict_update_drop` 1, `jf_vv` 1, `access` 1 |
| `tests/jit/*.tcl` | 2 | 8 | 13 | `ret` 12, `foreach_next` 6, `push` 2, `jf_vi` 1 |

The census found no loop in the outside programs: their loops are in method bodies and in procs of namespaces, and the census reads only the procs of the global namespace. The census did not run on the suite files, because they need the test environment of `tools/suite.sh`. The census counts loops and not loop passes: the share of passes in eligible loops was not measured.
## Results of tasks 19 to 23

Measured on x86-64 Linux on 2026-11-24 on the branch of these tasks.

| Check | Result |
|---|---|
| `zig build jit-fuzz -- --count 200000` (Debug), before task 23 | 200 000 programs, 1 000 000 runs, no difference. The mean is 476 bytecode instructions in 4.5 compiled functions for each program. |
| The same after task 23, in two parts of 100 000 | No difference. 5.7 and 7.0 compiled functions for each program, because named code compiles. |
| `zig build jit-fuzz -Doptimize=ReleaseSafe -- --seconds 3600` | 442 101 programs, 2 210 505 runs, no difference. This run had the code of task 23. |
| The planted bug (`-Djit_bug=true`, `--expect-diff`) | A difference at the program of seed 3655. |
| `zig build jit-fuzz -Doptimize=Debug -- --count 20000 --stress 31` | No difference. |
| `tools/jit-asm-golden.sh --random 1000000` | No difference. |
| `zig build jit-fuzz -Doptimize=ReleaseSafe -- --verify --count 1000000` | No crash. The verifier accepted 26.1 %: 0.44 % of the random Code values and 37.1 % of the changed ones. 260 979 compiled and ran. |
| `tools/jit-scan.sh` | Each check passes. A planted immediate operand in `litInt` makes check 1 fail. |

The share of sampled programs that ran each item of the grammar is above 5 % for each item except `coroutine` (1.2 %) and `namespace` (1.2 %). Those two run only at the top level.

The fuzzers found three faults:

- The verifier accepted a loop that counts no step, for example `jump 0`. The machine code then looped with no check of the step limit. The verifier now rejects such a cycle.
- The verifier lost two slices when its last allocation failed. Stress mode 1 found it.
- A named `Code` with `lset` or a dict update reads a cell of the frame by its slot. The verifier now rejects it.

Two costs of the interpreter showed in the tests. Each is outside the JIT:

- The memory limit is checked at the safe points of the step. One `string length` of a list nested 40 levels in itself allocated 1.1 GB with `--mem 67108864`, before the check stopped it.
- `recheck` reads each command at each change of the epoch. A loop that defines n procs then uses time in the order of n squared: 40 000 procs took 31 s for 120 000 steps.

A global loop of one million passes of `incr i` used 441.8 M instructions without the JIT and 487.8 M with it. Each variable instruction of named code is a helper call. An event script parses its script again at each event, so the JIT compiled the bodies of its loops again at each event. After about 4000 events the JIT memory limit stopped the compiler for the interpreter. Named code now has a quarter of the JIT memory. See [What compiles, and when](#what-compiles-and-when).

## Performance of calls and lists

This work makes call-heavy and list-heavy scripts faster in the interpreter and in both tiers. Each change below has a cause in this profile.

### The profile

Measured on 2026-11-24 on commit `958d3dd`, `ReleaseFast`, x86-64 Linux, with `valgrind --tool=callgrind`. Callgrind counts each instruction, so a share is exact for that run. `perf record` here gives no call graphs, and its samples put too much time on `memset`. `tiny.b` is `bench.b` with two levels of the inner loops removed: `bf.tcl` makes about 290 000 calls of `run` with it, and `bf_oo.tcl` about 965 000 method calls. A share is of the whole process, and "incl." includes the callees.

| Program | Instructions, interpreter / `--jit` | Cost | Share, interpreter | Share, `--jit` |
|---|---|---|---|---|
| `bf_oo.tcl tiny.b` | 7540 M / 7232 M | `::oo::Link` at the start of each method: `allocPrint` of each name (22.1 %), the linear search of the global frame (12.2 %) | 38.5 % incl. | |
| | | The call chain of each method call (`chainOf`) | 12.7 % incl. | |
| | | `findCommand` of the object name: once in `resolve`, once in `objCmd` | 10.2 % incl. | |
| | | `isPublic` for each call | 6.8 % incl. | |
| | | `lset` copies the tape | 3.1 % incl. | |
| `bf.tcl tiny.b` | 1307 M / 1045 M | `lset` copies the tape: `lsetOwned` (about 395 instructions each, 2 for each call of `run`) | 17.7 % incl. | 22.1 % incl. |
| | | The proc call: `callProc`, `vm.run`, the frame list, `resolve` | 12.8 % | 16.3 % |
| | | `heap.alloc` (also inside the `lset` copy and `list`) | 9.1 % | 11.4 % |
| | | `Value.asList` through a call for each list read | 5.9 % | 7.4 % |
| | | `list $tape $pos` through `invoke` and `cmdList` | 4.8 % incl. | 6.0 % incl. |
| | | `lassign` (the helper of tier 1) | | 15.6 % incl. |
| `fib.tcl` | 165.8 M / 137.3 M | `callProc` with `runProc`, alone | 26.4 % | 31.8 % |
| | | `vm.run` and `jit.enter`, alone | 13.9 % | 27.8 % |
| | | The helper of `invoke` | | 11.3 % |
| | | `resolve` and the list of free frames | 7.7 % | 4.4 % |
| `readloop.tcl` | 208.9 M | `mem.eql` of the list cache: each hit compares 599 bytes with a private copy | 27.8 % | |
| | | `readList` | 12.1 % | |

Facts from the profile:

- In `bf.tcl` the caller still holds the tape when `run` gets it, so the first `lset` in a call must copy, as in tclsh. The second copy comes from two places. A load of `$tape` for `lindex` ends the ownership of the cell. A `lset` that is the last command of a `switch` arm keeps its result, and a kept result also ends the ownership. tclsh counts references, so a value on its stack that goes away gives the ownership back.
- `bf_oo.tcl` spends 70 % of its instructions in the machinery of a method call, outside the method bodies.
- A call of `fib` with the JIT costs about 566 instructions: `callProc` 180, the machine code 118, `vm.run` and `jit.enter` 157, the helper of `invoke` 64, and the free frame list 42.

### The changes

| Change | Cause in the profile |
|---|---|
| A TclOO object keeps its last four call chains for one epoch of the OO state. A command site keeps the command of a name word that is not a literal. `::oo::Link` keeps the global cell of each name in the object. | `::oo::Link`, `chainOf`, `isPublic`, and the two lookups of the object name: about 70 % of `bf_oo.tcl` |
| A load for `llength` or `lindex` keeps an owned list owned. A dropped `lset` or `lassign` at the end of an arm of `if` or `switch` drops its result itself. A new list is one block. | The second `lset` copy in each call of `run` |
| A fast path for a proc call with a compiled body and exact arguments. A free frame keeps its cells for the next call of the same `Code`. A short entry of `vm.run` for ready machine code. | `callProc`, `vm.run`, and `jit.enter`: about 400 instructions for each call of `fib` |
| `Interp.list` reads a list value inline. Tier 1 has an inline `lassign_drop` and reads an owned cell inline for a load of an `access`. `str_eq_jump` compares inline. | `Value.asList` (7.2 %) and the helper of `lassign` (15.7 %) of `bf.tcl` with the JIT, after the changes above |
| The list cache compares the text of an entry once after each collection. | `mem.eql` of `readloop.tcl` |

The rule of an owned list is in [the design](design.md#the-bytecode): a list that a cell owns is in no other place, so no value that a script can see changes. `tests/jit/owned_lists.tcl`, `tests/jit/oo_cache.tcl`, and `tests/jit/op_lassign_drop.tcl` compare each case with tclsh 8.6.16 in each mode of `tools/jit-diff.sh`.

### Results

Measured on 2026-11-24, `ReleaseFast`, x86-64 Linux, with `perf stat -e instructions:u` of the whole process, against commit `958d3dd` in the same session.

| Script | Interpreter, before | after | `--jit`, before | after | `--jit --jit-tier2`, before | after |
|---|---|---|---|---|---|---|
| `puts hi` | 0.72 M | 0.73 M | 0.73 M | 0.73 M | 0.73 M | 0.73 M |
| `sum.tcl` | 283.8 M | 283.8 M | 90.9 M | 90.9 M | 15.1 M | 15.1 M |
| `fib.tcl` | 165.8 M | 150.3 M | 137.4 M | 107.0 M | 137.4 M | 107.0 M |
| `nested.tcl` | 337.6 M | 333.4 M | 123.8 M | 123.5 M | 55.4 M | 55.1 M |
| `strbuild.tcl` | 324.0 M | 323.0 M | 252.6 M | 252.6 M | 243.2 M | 243.2 M |
| `foreach.tcl` | 213.8 M | 206.9 M | 80.4 M | 80.4 M | 40.7 M | 40.6 M |
| `dict.tcl` | 281.0 M | 280.8 M | 194.9 M | 194.9 M | 188.6 M | 188.6 M |
| `dictgrow.tcl` | 645.6 M | 642.9 M | 572.4 M | 572.4 M | 570.4 M | 570.4 M |
| `dsum.tcl` | 700.8 M | 688.8 M | 558.0 M | 556.0 M | 16.6 M | 16.6 M |
| `readloop.tcl` | 208.9 M | 145.3 M | 154.7 M | 93.3 M | 146.9 M | 85.3 M |

`tools/jit-perf.sh --check off`, `--check jit`, and `--check jit2` pass. The two gates that failed before pass now: `fib.tcl` 107.0 M (gate 112 M) and `readloop.tcl` 93.3 M (gate 150 M). `puts hi` is 3017 instructions above the baseline, and the limit is 5000.

The outside programs with `tools/kostya.sh` and `bench.b`, against `tclsh` 8.6.16 in the same session. Each output equals the output of `tclsh`. The ratio is the instructions of ztcl over the instructions of `tclsh`.

| Program | Mode | ztcl before | ztcl after | Ratio before | Ratio after |
|---|---|---|---|---|---|
| `bf.tcl` | interpreter | 1309.0 G | 1005.8 G | 0.472 | 0.363 |
| `bf.tcl` | `--jit` | 1047.9 G | 680.8 G | 0.378 | 0.245 |
| `bf.tcl` | `--jit --jit-tier2` | 1053.2 G | 686.1 G | 0.380 | 0.247 |
| `bf_oo.tcl` | interpreter | 7452.3 G | 2445.7 G | 1.387 | 0.455 |
| `bf_oo.tcl` | `--jit` | 7150.5 G | 1970.0 G | 1.331 | 0.367 |
| `bf_oo.tcl` | `--jit --jit-tier2` | 7156.6 G | 1975.3 G | 1.332 | 0.368 |
| `base64/test.tcl` | each mode | 50.7 G | 50.7 G | 0.701 | 0.701 |

`tclsh` used 2774 G instructions for `bf.tcl`, 5372 G for `bf_oo.tcl`, and 72.4 G for `base64/test.tcl`. The targets of this work were `bf.tcl` at most 0.25 and `bf_oo.tcl` at most 1.0.

Wall time, best of 5, each run on one processor with `taskset`, with `small.b` (`bench.b` with one level of the inner loops removed). Other jobs shared the machine (load average about 10 on 8 processors), so each time is noisy: `base64/test.tcl` gave 5.1 s and 7.0 s for two builds with equal instruction counts.

| Program | Mode | Before | After | `tclsh` |
|---|---|---|---|---|
| `bf.tcl small.b` | interpreter | 1.43 s | 1.07 s | 3.06 s |
| `bf.tcl small.b` | `--jit` | 1.20 s | 0.69 s | |
| `bf.tcl small.b` | `--jit --jit-tier2` | 1.18 s | 0.78 s | |
| `bf_oo.tcl small.b` | interpreter | 9.82 s | 3.24 s | 6.26 s |
| `bf_oo.tcl small.b` | `--jit` | 8.88 s | 2.62 s | |
| `bf_oo.tcl small.b` | `--jit --jit-tier2` | 9.12 s | 2.17 s | |
| `fib.tcl` | `--jit` | 37 ms | 29 ms | 109 ms |
| `readloop.tcl` | `--jit` | 32 ms | 23 ms | 46 ms |

The tests: `zig build test` in Debug, in `ReleaseSafe`, and with `-Djit=false`; the wasm build with `tools/wasm-smoke.mjs` and `tools/wasm-mem.mjs`; `tools/suite.sh -a`, `-a -j`, and `-a -J` with the suite runner, each 37 383 with each of the 152 files equal to the run of `958d3dd`; `tools/jit-diff.sh` and `-t`; `zig build jit-fuzz -Doptimize=ReleaseSafe -- --tier2 --seconds 600` (38 000 programs, 266 000 runs, no difference); and `tools/gc-fuzz.py -j -T -g 1` with a `ReleaseSafe` suite runner (300 programs, no difference: one run reached the time limit, and one stopped at another depth at the nesting limit, as in milestone 1).

These checks were reversed one at a time, and a test failed each time: the change of the OO epoch in a definition, the filter check and the export check of the chain cache, the namespace check of the link cache, the epoch check of the command site, the flag of the peek load, the use of an arm, the reset of the kept cells, the `Code` check of the kept cells, the length reset of a free frame, the list tag check and the end check of the inline `lassign_drop`, and the length check of the inline compare of `switch`. Two checks have no test that fails. The check of the name in `Interp.siteCommand` is not reachable from a script: each caller of a native command passes the name word of its own site. The count of collections in the list cache repeats a rule that holds already, because each collection clears the cache. The changes of the OO epoch at an object creation, an object end, and a copy were not reversed one at a time.

### Results after the rebase onto main

The work was rebased onto main at `a3264ca`, after threads, the hard memory cap, and the step charges. Measured on 2026-11-24, `ReleaseFast`, x86-64 Linux, with `perf stat -e instructions:u` of the whole process, against main at `ec48644` (the three later commits of main change no code of these paths). Other jobs shared the machine.

| Script | Interpreter, main | branch | `--jit`, main | branch | `--jit --jit-tier2`, main | branch |
|---|---|---|---|---|---|---|
| `puts hi` | 0.73 M | 0.73 M | 0.74 M | 0.74 M | 0.74 M | 0.74 M |
| `sum.tcl` | 283.8 M | 283.8 M | 90.9 M | 90.9 M | 15.0 M | 15.0 M |
| `fib.tcl` | 166.5 M | 151.0 M | 136.4 M | 106.0 M | 136.4 M | 106.0 M |
| `nested.tcl` | 337.7 M | 333.5 M | 123.9 M | 123.6 M | 55.6 M | 55.4 M |
| `strbuild.tcl` | 323.9 M | 322.9 M | 252.5 M | 252.5 M | 243.1 M | 243.1 M |
| `foreach.tcl` | 213.8 M | 206.9 M | 80.4 M | 80.4 M | 40.6 M | 40.6 M |
| `dict.tcl` | 280.9 M | 280.7 M | 194.9 M | 194.9 M | 188.6 M | 188.6 M |
| `dictgrow.tcl` | 665.5 M | 647.7 M | 589.9 M | 590.3 M | 587.8 M | 595.7 M |
| `dsum.tcl` | 700.8 M | 688.8 M | 557.9 M | 555.9 M | 16.6 M | 16.6 M |
| `readloop.tcl` | 208.9 M | 145.3 M | 154.7 M | 93.3 M | 146.9 M | 85.3 M |

`dictgrow.tcl` changes by about 1 % between two runs of one build: the branch gave 588.3 M and 595.7 M with tier 2.

`tools/jit-perf.sh --check off`, `--check jit`, and `--check jit2` fail on main and on the branch at the same rows: `puts hi` is 8768 instructions above the baseline on main and 10 252 on the branch (limit 5000), and `dictgrow.tcl` is about 2 % above its gates of `jit` and `jit2`. Each other row passes on the branch. On main, `fib.tcl`, `foreach.tcl`, and `readloop.tcl` also fail.

`tools/kostya.sh --jit` with `bench.b`. The ratio is the instructions of ztcl over the instructions of `tclsh` 8.6.16 (2774.0 G for `bf.tcl`, 5371.9 G for `bf_oo.tcl`, and 72.4 G for `base64/test.tcl`). Each output of the branch equals the output of `tclsh`.

| Program | main | branch | Ratio, main | Ratio, branch |
|---|---|---|---|---|
| `bf.tcl` | 1047.2 G | 680.2 G | 0.378 | 0.245 |
| `bf_oo.tcl` | 7116.1 G | 2002.7 G | 1.325 | 0.373 |
| `base64/test.tcl` | | 50.7 G | | 0.701 |

Wall time, best of 5, each run on one processor with `taskset`, with `small.b` (`bench.b` with one level of the inner loops removed). Other jobs shared the machine (load average about 12 on 8 processors), so each time is noisy. The outputs of all runs of a row are equal.

| Program | Mode | main | branch |
|---|---|---|---|
| `bf.tcl small.b` | interpreter | 2.39 s | 1.69 s |
| `bf.tcl small.b` | `--jit` | 1.81 s | 1.33 s |
| `bf_oo.tcl small.b` | interpreter | 19.30 s | 5.31 s |
| `bf_oo.tcl small.b` | `--jit` | 15.85 s | 4.37 s |
| `fib.tcl` | `--jit` | 23 ms | 22 ms |
| `readloop.tcl` | `--jit` | 27 ms | 17 ms |

## The design of the JIT

### The tiers

| Tier | What it is | State at an instruction boundary |
|---|---|---|
| 0 | The interpreter (`vm.exec`). | The value stack, the cells, `pc`, and `sp`. |
| 1 | A template compiler. One bytecode instruction gives one fixed piece of machine code with an inline fast path and a call of a helper for the slow path. | The same as tier 0. No value is in a register across a boundary. |
| 2 | A compiler for one hot loop. Integers and doubles are in registers. Guards check the guesses. | Registers and constants. A table for each exit gives the place of each value. |

**Why tier 1 is a template compiler.** The state of tier 1 equals the state of the interpreter at each boundary. So a switch between the two needs only `pc` and `sp`, and tier 1 needs no on-stack replacement tables. Each slow path calls the function that the interpreter calls, so each rare case has one implementation. V8 uses this design for Sparkplug, and SpiderMonkey and JavaScriptCore use it for their baseline compilers.

**Why not copy-and-patch.** Copy-and-patch makes the templates from compiled C code at build time and needs Clang or LLVM tools for the stencils. ztcl builds with the Zig toolchain alone and for five targets. The templates of tier 1 are small, so an assembler by hand is less work than a stencil tool.

**Why tier 2 is a loop compiler and not a trace compiler.** A trace compiler records one path through a loop. A patent on trace compilation may be active: US 8,769,511, "Dynamic incremental compiler and method", filed 2007-02-16 and granted 2014-07-01 to the University of California. LuaJIT and PyPy ship trace compilers as open source. The author is not a lawyer and did not check the claims or the legal status. A compiler for a whole loop with type guesses avoids the question. Method compilers with type speculation and deoptimization date from the Self system (1992), and each claim of that age has expired.

### What compiles, and when

- A proc body compiles to tier 1 at its second call. A body with a loop compiles at its first call. The compile is linear in the count of bytecode instructions, so a low threshold is safe.
- A script outside a proc (`Code.named`) compiles to tier 1 from task 23 on. Its variables use names, so each variable access calls a helper. It runs in any frame, so `jit.enter` does not check the size of the frame. The verifier rejects a named `Code` with `dict_update`, `dict_update_drop`, `lset`, or `lset_drop`, because their helpers read a cell of the frame by its slot, and a named `Code` whose one `ret` is not its last instruction of the main code.
- Named code has its own part of the JIT memory: a quarter of `jit_mem_limit`, for an interpreter and its children together. An event script parses its script again at each event, so the body and the step of each of its loops are new named `Code` values at each event, and each one compiles at its own threshold. Each compile uses at least one page. With no part, about 4000 events filled the JIT memory limit and stopped the compiler for the whole interpreter. When the part is full, named code stays in the interpreter, and procs keep the other three quarters. `--jit-stats` prints `named_bytes` and `named_stops`. The text cache of the interpreter now gives an event script or an `eval` text that comes again the same `Script`, so its loops compile one time (see `docs/design.md`). The part stays for texts that change at each event, such as a script with the event number in it.
- With `--jit-threshold 0`, each `Code` compiles before its first run. The tests use this mode.
- A `Code` that the verifier refuses, or that fails to compile, stays in the interpreter. The compiler tries each `Code` one time.
- A loop compiles to tier 2 when its tier 1 code counts 1000 passes. The count is a field of the JIT data of the loop.

Tier 1 needs no entry in the middle of an interpreter run, because it compiles before the run starts. After an error that `vm.run` handles (`break` or `continue` from a general command), `run` enters the tier 1 code again at the target `pc`.

### The entry and the exit of tier 1

`vm.run` keeps its form. It calls `jit.enter` in place of `exec` when the `Code` has machine code:

```zig
const out = if (code.jit) |j| jit.enter(it, j, code, stack.ptr, &pc, &sp) else exec(...);
```

- The machine code of a `Code` is one function with the C calling convention and one argument: a pointer to an `EnterCtx` on the native stack. The context has the interpreter, the `Code`, the frame, the value stack, the helper table, the target address, `pc`, `sp`, and the error.
- `jit.enter` computes the target address from a table with one entry for each bytecode address. It checks that `pc` is in range, that `sp` equals the static depth of that address, and that the target is inside the function. A failed check runs `exec`.
- The function returns a status: 0 for a result (at `stack[sp - 1]`), 1 for a Zig error (in the context), 2 for a fallback to `exec` at `ctx.pc` and `ctx.sp`.
- A call of a helper that can fail has a cold stub. The stub writes the bytecode address and the static depth to the context and returns status 1. So `run` sees the same `pc` and `sp` as with `exec`, and the error trace, `break`, and `continue` work with no change.
- The depth of the value stack is static at each address. The verifier computes it. So the machine code has no `sp` register: each stack value has a fixed offset.

### The machine code has no absolute address and no script constant

- A helper call is an indirect call through a table of function pointers. The table is a constant of the binary. A pinned register holds its address.
- A literal comes from `code.lits` at run time. An integer literal of a script is never an immediate operand.
- The instruction stream has only opcodes, register numbers, branch offsets, and small numbers that the compiler bounds: a slot index, a literal index, a stack offset, a bytecode address, and a field offset.

So the code is position independent, has no pointer that an attacker can read, and has no bytes that a script selects freely. This is the defense against JIT spraying. See [Security](#security).

### The pinned registers

| Purpose | x86-64 | arm64 |
|---|---|---|
| The interpreter | `r15` | `x19` |
| The `Code` | `r14` | `x20` |
| The value stack | `r13` | `x22` |
| The helper table | `r12` | `x23` |
| The frame | `rbx` | `x21` |
| The frame pointer | `rbp` | `x29` |
| Scratch | `rax`, `rcx`, `rdx`, `r8` to `r11` | `x9` to `x15` |

Each pinned register is callee-saved in the System V ABI, the Microsoft x64 ABI, and AAPCS64. The scratch set is caller-saved in all three. `rsi` and `rdi` are callee-saved on Windows, so the templates use them only for arguments. arm64 code never uses `x18`. A helper has at most four integer arguments, so each ABI passes them in registers.

### The layout of values

`Value` and `Var` are Zig tagged unions, and Zig does not fix their layout. The JIT reads four facts at start: the offset and the mask of the tag of `Value`, the offset and the mask of the tag of `Var.v`, the offset of each payload, and the number of each tag. `jit/layout.zig` finds them with a probe: it writes two values that differ only in the tag and compares the bytes. In the builds of today, the tag of `Value` is at byte 16 of 24, and the tag of `Var.v` is at byte 24 of 40.

If the probe finds a layout that it does not understand, the JIT stays off for the process. A copy of a `Value` in machine code is two 8-byte moves and one byte move for the tag. A 16-byte load after an 8-byte store of the same bytes stalls the processor.

### The helpers

Each slow path of `vm.exec` becomes a named function in `vm.zig` that both the interpreter and the helpers call. `jit/helpers.zig` wraps each one with the C calling convention: the wrapper returns 0, or stores the Zig error in the context and returns 1. The helper table is an array of these wrappers.

The inline fast paths of tier 1, in the order of their gain:

1. `guard`, `step`: the epoch compare, the step limit, and the memory limit.
2. `jump`, `jf_vv`, `jf_vi`, `jump_false`, `jump_true`: integer compares.
3. `bin_vv`, `bin_vi`, `binary`: `+`, `-`, `*`, and the six compares on two integers, with the overflow check.
4. `load`, `store`, `store_pop`, `push`, `push_empty`, `pop`.
5. `incr`, `incr_drop`, `incr_value` on an integer cell.
6. Milestone 2: `foreach_next`, `lappend` when the list has room, `llength` and `lindex` on a list value, `/` and `%` on integers, and a direct call of a proc.

Each other case calls a helper. A slot that holds a link (`upvar`, `global`) follows the link in a small loop outside the hot path. A cell with a trace, an array, an element link, or an owned dict goes to the helper.

### Tier 2

Tier 2 compiles one loop: the instructions from a loop head to its back jump. The work has these parts.

- **The guess.** At the 1000th pass, tier 2 reads the kind of each slot that the loop uses. An `int` cell gives the guess `int`, and a `double` cell gives `double`. Other kinds stay in their cells. Tier 1 needs no type feedback code.
- **The check.** A forward pass over the loop gives a type to each stack value and each slot at each instruction. A loop compiles only when the types at the back jump equal the types at the head.
- **The entry.** The tier 1 code calls `jit.tierUp` at the loop head. The entry block of the tier 2 code checks that each slot is a direct `.val` cell of the guessed kind, and loads it into a register. Two slots that link to one cell fail this check, so the registers have no alias.
- **Guards.** A guard is at an instruction boundary, before any effect of that instruction. A failed guard is an exit.
- **Exits.** Each exit has a record: the bytecode address, the place and kind of each slot and stack value, and the count of steps to give back. `jit.deopt` writes the values to the cells and the value stack and returns to `run`, and tier 1 continues at that address.
- **Calls out.** Before a call of a helper that can run a script, tier 2 writes each changed register to its cell. After the call, it checks the epoch and each slot again and loads the registers. So `upvar`, `uplevel`, traces, and a redefined command see and change the true cells.
- **A loop that exits often.** After 8 exits of one loop, the JIT drops its tier 2 code and never compiles that loop again.

Tier 2 uses at most 5 registers for values on x86-64. Other values stay in their cells, with no tag check inside a part of the loop that has no call. The first version has no inlining of procs.

### The step limit and the memory limit

Tier 1 runs the same bytecode instructions as the interpreter, in the same order. Each `guard`, `step`, `invoke`, and `foreach_next` has the same check at the same place: the step count is zero, then the count goes down by one, then the memory count is above the limit. So the step count after a script is equal in both modes, and a script stops at the same instruction. Each helper that the interpreter also calls counts its own steps as today.

Tier 2 can join the checks of a part of a loop that has no call and no branch target. The part has `k` steps. The code checks that at least `k` steps are left and subtracts `k`. If fewer are left, it exits at the start of the part with no step used, and the interpreter stops at the exact instruction. An exit in the middle of a part gives back the steps of the instructions that did not run. No code in such a part allocates, so one memory check at the entry of the loop and one after each call equal the checks of the interpreter.

**JIT memory does not count in `mem_limit`.** All memory of the JIT comes from the allocator of the embedder and from the executable region, and it has its own limit (`jit_mem_limit`, 16 MiB by default). The counter of the heap never sees it. So a script reaches the memory limit at the same instruction in both modes, and rule 4 of AGENTS.md stays true: the output of a script does not depend on the JIT. When the JIT limit is reached, the compiler stops, and the interpreter runs the rest.

### How the semantics of Tcl stay exact

| Feature | Mechanism |
|---|---|
| A redefined or renamed command | Each inline form keeps its `guard`. The machine code compares `epoch` with `safe_epoch`, calls `recheck`, and jumps to the cold block, as the interpreter does. `invoke` calls `Interp.resolve`, which checks the epoch and the namespace of the site. |
| Variable traces | `var_traces` above zero makes `recheck` fail, so each inline form runs on the general path. A traced cell does not have the tag `.val`, so each inline read and write goes to the helper. |
| `upvar`, `global`, `variable` | The cells of `Frame.vars` are the one place of each variable in tier 1. The code loads `vars.items` again at each access, because a helper can grow the list. Tier 2 writes its registers back before each call. |
| `uplevel`, `eval`, `namespace eval` | They run on the general path or as named code. They read and write the same cells. |
| Shimmering | A value never changes its kind in place. The code reads the tag at each use. A string that looks like a number goes to the helper, which gives the result of the interpreter. |
| Errors and `errorInfo` | A stub for each call writes the exact bytecode address. `run` adds the commands of the ranges to the trace as today. The helpers set `errorCode` and the line. |
| `return`, `break`, `continue`, custom codes | They are Zig errors in a helper. The status path gives them to `run`, which has the range table. |
| `catch`, `try` | They are general commands. The step limit error and the memory error stay uncatchable, because the helpers raise them as today. |
| Coroutines | A coroutine runs machine code on its own native stack. `yield` is a helper call, so the switch saves the callee-saved registers as for Zig code. The JIT frame has a fixed size below 256 bytes, and `checkNative` runs before each entry. `coro.zig` does not change. |
| `tailcall` | It is a private return code. The status path gives it to `callProc`. |
| TclOO | A method body is a proc body: `callMethod` calls `runProc`. `my`, `next`, and `self` are commands. |
| The event loop | An event script runs at the global level through `evalScript`. No code interrupts machine code, so the JIT needs no safe points. |
| `interp` | Each interpreter has its own JIT state. A child has the JIT only when its parent has it. |
| `compact`, `reset`, `deinit` | Each one frees all machine code of the interpreter first. They cannot run while a script runs, so no native frame returns into freed code. |
| The native stack limit | The machine code of one proc call must use no more native stack than `exec`. A test measures it. A deep recursion can pass in one mode and fail in the other only at the `max_native` limit, as between a debug build and a release build today. |
| Point procs | The slow path compiles as a proc. Tier 1 has no inline code for doubles. Tier 2 uses only `addsd`, `subsd`, `mulsd`, `divsd`, and the compares, with no fused multiply-add, so each result has the bits of the Zig code. |

### Files

All new code is in new files. The JIT changes no line of `src/coro.zig`, `src/sys.zig`, `src/sys_windows.zig`, `src/fsroot.zig`, or `src/proc.zig`, so it does not collide with the ports on `ports3`.

| File | What it has |
|---|---|
| `src/jit.zig` | The state, the options, `enable`, `maybeCompile`, `enter`, `flush`, and the counts. |
| `src/jit/mem.zig` | The executable region for each system. |
| `src/jit/layout.zig` | The layout probe. |
| `src/jit/verify.zig` | The bytecode verifier and the static stack depths. |
| `src/jit/helpers.zig` | The helper table. |
| `src/jit/abi.zig` | The registers and the calling convention of each target. |
| `src/jit/x64.zig`, `src/jit/a64.zig` | The assemblers. |
| `src/jit/tier1.zig`, `src/jit/tier1_x64.zig`, `src/jit/tier1_a64.zig` | The template compiler and the templates. |
| `src/jit/tier2.zig`, `src/jit/tier2_lower.zig`, `src/jit/tier2_x64.zig` | The plan of a loop, the facts of the plan that each backend reads, and the code of tier 2 for x86-64. |
| `src/jit/unwind_win.zig` | The unwind tables for Windows. |
| `src/jit/tests.zig` | The unit tests. |
| `tests/jit/` | The scripts of the differential tests. |
| `tools/jit-diff.sh`, `tools/jit-perf.sh`, `tools/jit-fuzz.zig`, `tools/jit-asm-golden.sh` | The test tools. |

Small changes go in `build.zig`, `src/ztcl.zig`, `src/vm.zig`, `src/interp.zig`, `src/compact.zig`, `src/child.zig`, `src/main.zig`, and `tools/suite.sh`. `ports3` also changes `interp.zig`, `main.zig`, and `ztcl.zig`. Each task names its hunks, and they rebase by hand.

## Targets

The order is x86-64 Linux, arm64 macOS, x86-64 macOS, x86-64 Windows, arm64 Linux.

| Target | ABI | Executable memory | Instruction cache | Unwinding | State of this plan |
|---|---|---|---|---|---|
| x86-64 Linux | System V | `mmap` read-write, then `mprotect` read-execute | no call needed | Frame pointers. No table. | Measured on this machine. |
| arm64 macOS | AAPCS64 with the Apple rules | `mmap` with `MAP_JIT`, `pthread_jit_write_protect_np` | `sys_icache_invalidate` | Frame pointers (`x29`). No table. | Not tested. No machine was available. |
| x86-64 macOS | System V | `mmap` read-write with `MAP_JIT`, then `mprotect` read-execute | no call needed | Frame pointers. No table. | Not tested. |
| x86-64 Windows | Microsoft x64 | `VirtualAlloc` read-write, then `VirtualProtect` to `PAGE_EXECUTE_READ` | `FlushInstructionCache` | `RtlAddFunctionTable` with one unwind record for each function | Not tested. |
| arm64 Linux | AAPCS64 | `mmap` read-write, then `mprotect` read-execute | `__clear_cache` of the Zig runtime | Frame pointers. No table. | Not tested. |
| WebAssembly | | none | | | The interpreter only, with the collector at bytecode safe points. |

### Rules for each ABI

- **System V x86-64.** Arguments are in `rdi`, `rsi`, `rdx`, `rcx`. The stack pointer is 16-byte aligned at each call. The code does not use the red zone.
- **Microsoft x64.** Arguments are in `rcx`, `rdx`, `r8`, `r9`. Each call has 32 bytes of shadow space. `rsi`, `rdi`, and `xmm6` to `xmm15` are callee-saved. Tier 2 on Linux uses them, so the Windows port saves them or uses other registers.
- **AAPCS64.** Arguments are in `x0` to `x3`. The stack pointer is 16-byte aligned at all times. `x29` and `x30` make the frame record. The code never uses `x18`. Tier 2 uses only `d0` to `d7` and `d16` to `d31`. Plain arm64 builds have no pointer authentication.

### Stack probes

A JIT frame has a fixed size below 256 bytes: the saved registers, the context pointer, and the shadow space on Windows. It is smaller than one page, so it needs no probe (`__chkstk`) on Windows and no probe on the other systems. The code has no variable stack allocation. `checkNative` in `vm.run` bounds the depth before each entry, as for `exec`.

### Unwinding

ztcl has no exceptions: an error is a return value. No unwinder must cross a JIT frame for correct results. Each JIT frame keeps the frame pointer chain, so a profiler and the stack walk of a Zig panic can pass it.

Windows is the exception. The system unwinder treats code with no function table entry as a leaf function, and a walk through such a frame fails. An embedder with a crash handler needs correct walks. So the Windows port registers one `RUNTIME_FUNCTION` for each compiled function with `RtlAddFunctionTable`, and removes it with `RtlDeleteFunctionTable` before the memory is free. The prologue has one fixed form, so one unwind record form serves all functions.

### Coroutine stacks

A coroutine stack is 1 MiB in a release build and comes from the arena, with no guard page. `max_native` is half of it. The JIT adds no rule: its frame is small and fixed, and it calls `checkNative` through `vm.run`. On Windows, `coro.zig` on `ports3` swaps the stack bounds of the thread block. The JIT code does not read them. No unwind crosses a switch.

### WebAssembly

A WebAssembly module cannot make machine code and jump to it. A module can ask its host to compile a new module, but ztcl is a freestanding library with no host interface for that, and each call between two modules has a cost. So the WebAssembly build keeps the interpreter, and `build.zig` forces the JIT option off for it.

A faster path for WebAssembly is work on the interpreter itself: shorter handlers and fused instructions. The profile shows about 33 machine instructions for one bytecode instruction, so that work has room. It needs its own measurement on a WebAssembly runtime, and it is an open decision.

## Security

ztcl runs scripts that the embedder does not trust. The JIT adds machine code that a script shapes, so it adds risk. SECURITY.md already says that ztcl must not be the only barrier.

### The threat model

The attacker controls the script. The attacker does not control the embedder, the process, or other threads. The goals of the attacker are to run machine code of their choice, to read or write memory outside the values of the script, to pass a limit, and to crash the host.

### No page is writable and executable

- The region is one reservation with no access. The compiler assembles each function in a normal buffer first. It then makes new pages of the region writable, copies the function, fills the rest of the last page with trap instructions, makes the pages executable, and flushes the instruction cache. A page is writable or executable at each instant, never both.
- The code is write-once. On Linux, Windows, and an Intel Mac, each function starts on a new page, and a page that is executable never becomes writable again. So a failed protection change cannot harm a function that exists. On Apple silicon the write switch is a state of the thread for all `MAP_JIT` pages, so the functions pack with 16-byte alignment.
- No byte of a function changes after the copy: the code has no inline cache and no patch. A stress mode keeps a checksum of each function and checks it.
- The page before the region and the pages after the used part have no access.
- The trap instructions are `int3` on x86-64 and zero words (`udf`) on arm64.
- ztcl never maps one page two times with different rights.

| System | Calls | When the call fails |
|---|---|---|
| Linux | `mmap(PROT_NONE)`, `mprotect(PROT_READ or PROT_WRITE)`, `mprotect(PROT_READ or PROT_EXEC)` | The JIT is off. This is the case under SELinux `execmem` rules, a seccomp filter, or `PR_SET_MDWE`. |
| arm64 macOS | `mmap` with `MAP_JIT`, `pthread_jit_write_protect_np(0)` to write, `pthread_jit_write_protect_np(1)` to run, `sys_icache_invalidate` | The JIT is off. With the hardened runtime, the embedder needs the entitlement `com.apple.security.cs.allow-jit`. |
| x86-64 macOS | `mmap(PROT_READ or PROT_WRITE)` with `MAP_JIT`, then `mprotect(PROT_READ or PROT_EXEC)` | The JIT is off. |
| Windows | `VirtualAlloc(MEM_RESERVE)`, `VirtualAlloc(MEM_COMMIT, PAGE_READWRITE)`, `VirtualProtect(PAGE_EXECUTE_READ)`, `FlushInstructionCache` | The JIT is off. This is the case under the dynamic code policy (ACG). |

Notes on macOS:

- On Apple silicon, the write protection of `MAP_JIT` memory is a state of the thread. The compiler turns it off only around the one copy, on the thread of the interpreter. One thread uses one interpreter at a time.
- On an Intel Mac, `pthread_jit_write_protect_np` does no work, and a `MAP_JIT` region with write and execute rights is writable and executable at once. So the Intel port never asks for both rights. The author did not test that `mprotect` works on a `MAP_JIT` region under the hardened runtime. The task has this test.
- ztcl never needs `com.apple.security.cs.allow-unsigned-executable-memory` or `com.apple.security.cs.disable-executable-page-protection`. An embedder must not add them for ztcl.
- The entitlement belongs to the app that embeds ztcl. zslice decides if it ships with `allow-jit`. With no entitlement, the `mmap` fails, and ztcl runs the interpreter.
- Apple also has `pthread_jit_write_with_callback_np` with the entitlement `com.apple.security.cs.jit-write-allowlist`. It limits the code that can write to the region. It is an open decision.

Notes on Windows: ztcl never uses `PAGE_EXECUTE_READWRITE`. Zig does not emit Control Flow Guard checks, so the call from `jit.enter` needs no call target registration. The machine code uses only `call` and `ret` pairs, so it is correct under a shadow stack.

Notes on arm64: a core can run old bytes from its instruction cache. The compiler flushes the cache for the exact range of each new function before the first run.

### A build or a system with no executable memory

`jit.enable` returns false, and the interpreter runs each script, when one of these is true:

- The build has `-Djit=false`, or the target has no backend.
- The layout probe fails.
- The reservation or the first protection change fails.
- A self-test function (it returns a constant) does not return its value.

A later failure of a protection change stops the compiler for that interpreter. Machine code that exists stays valid. No failure of the JIT is an error of a script.

### JIT spraying and constant blinding

JIT spraying puts bytes of the attacker in executable memory through constants of the script, then jumps into the middle of an instruction. Constant blinding is the usual defense: the compiler masks each constant with a random number.

ztcl uses a stronger and simpler rule. **No value of a script is an immediate operand.** Integer literals, the step of `incr`, and string bytes stay in `code.lits`. That array is data. The numbers that a script can influence in the instruction stream are indexes and offsets, and the compiler bounds each one:

| Number | Bound |
|---|---|
| Bytecode instructions of one `Code` | 32 768 |
| Slots of one `Code` | 2048 |
| Depth of the value stack | 2048 |
| Literals, sites, words, nodes, tables | 65 536 each |

A `Code` above a bound stays in the interpreter. So a 32-bit operand that a script influences has at most 20 bits that can vary, and its value is a multiple of a slot size plus a fixed offset. Blinding is then not needed. If a later task puts a script value in an instruction, that task must add blinding.

Other limits on the attacker:

- The address of the region comes from the system (ASLR). The code has no absolute address, so a read of the code gives no address.
- The entry table has offsets. `jit.enter` checks that each target is inside its function.
- The helper table is a constant of the binary.

### Bounds and type guards

- **The verifier.** Before a `Code` compiles, `jit/verify.zig` checks each instruction: the opcode, each jump target, each index (slot, literal, site, word, node, table), the stack depth at each instruction (at least the inputs of the instruction, at most `max_stack`, and equal on each path to one address), the depth at each `break` and `continue` target, that `ret` ends each path, and that each loop passes through an instruction that counts a step (`step`, `guard`, `invoke`, `eval_cmd`, or `foreach_next`). A `Code` that fails stays in the interpreter. The machine code reads memory only at offsets that the verifier proved.
- **The frame.** The function checks at its entry that the frame has at least `code.names.len` entries. A smaller frame runs `exec`.
- **Tags.** Each inline path checks the tag of the cell and the tag of the value before it reads a payload. An unknown tag goes to the helper. No inline path trusts a tag from an earlier instruction in tier 1.
- **Lists.** An inline index into a list buffer checks the index against the length of the view with an unsigned compare.
- **Integers.** `+`, `-`, `*`, and `incr` check the overflow flag. A division checks for zero and for the one case that overflows. A shift goes to the helper.
- **Tier 2.** Each guess has a guard. An exit record has a bound check when `jit.deopt` reads it.

### Limits that hold in machine code

- The step limit and the memory limit are exact. See [above](#the-step-limit-and-the-memory-limit).
- `max_depth`, `max_nest`, and `max_native` are checked by the same functions as today: `pushFrame`, `vm.run`, and `checkNative`.
- The JIT memory limit bounds the region and all JIT data. A script that defines procs without end fills the limit, and the compiler stops. The script then runs in the interpreter and still has its own limits.
- The compile time of one `Code` is linear, and the bound on bytecode instructions bounds it.

### Fuzzing

- **Differential fuzzing.** `tools/jit-fuzz.zig` makes random Tcl programs from a grammar: procs, loops, `expr`, lists, dicts, strings, `upvar`, `uplevel`, `catch`, `rename`, traces, and errors. It runs each program in the interpreter and in each JIT mode, with a random step limit, a random memory limit, and the collector off (`--gc off`). The output, the result, `errorInfo`, `errorCode`, the steps used, and the memory count must be equal.
- **Assembler fuzzing.** Each instruction form of each assembler is checked against the assembler of `zig cc` for each register and for the edge values of each operand.
- **Verifier fuzzing.** Random and mutated bytecode goes to the verifier. Each `Code` that passes then compiles and runs under a step limit in a build with safety checks, in one interpreter with the JIT and in one without it, with the same history. The process must not crash, and the result, `errorInfo`, the steps used, the memory count, and the output must be equal. Some runs have a step limit below 64 or a small memory limit.
- **Stress modes.** One mode compiles each `Code` at once. One mode forces each tier 2 guard to fail on a schedule. One mode makes each allocation of the compiler fail in turn.

### On by default, or a capability

The JIT is not a `Capability`. A capability adds commands that a script can see, and `compact` refuses an interpreter with capabilities. The JIT adds no command, and a script cannot see it or turn it on.

- **The build option** `-Djit` is true by default on a target with a backend. With false, the binary has no JIT code.
- **The embedder option** is off by default: `Interp.enableJit(options)` turns it on and returns false when the system has no executable memory. A child interpreter has the JIT only when its parent has it.
- **The runner** has `--jit`, off by default.

### The condition for a default of on

The runner flag can default to on for one target when all of these are true for that target. The library option stays an explicit call of the embedder in each case.

1. The differential suite passes on all 152 test files in three modes (threshold 0, default threshold, and tier 2 stress), with each count equal to the count of the interpreter.
2. The differential fuzzer ran 72 hours of processor time with no difference and no crash, and the assembler and verifier fuzzers ran 24 hours each.
3. The unit tests and the suite pass in a `Debug` build and a `ReleaseSafe` build with the JIT on.
4. A reviewer who did not write the code completed [the review checklist](jit-review.md), and no security finding is open.
5. Each performance gate passes, also the outside gates, and no benchmark is slower than the interpreter.
6. The JIT ran in zslice as an opt-in for 30 days with no bug from the JIT.

## Verification

| Check | What it proves | Task |
|---|---|---|
| `zig build test` and `zig build test -Djit=false` | The unit tests pass with and without the JIT code. | each |
| `tools/jit-diff.sh` | Each script of `tests/jit/` and `bench/` gives the same output, exit code, step count, and memory count in each mode. The memory count uses `--gc off`. | 18 |
| `tools/suite.sh -j` | The suite with `--jit --jit-threshold 0`. Each file has the pass count of the interpreter: 19 877 for the 37 core files and 37 383 for all 152 files with the suite runner. | 18 |
| The step limit sweep | A script runs with each step limit from 0 to its full count. Both modes stop with the same output. | 18 |
| `zig build jit-fuzz` | See [Fuzzing](#fuzzing). | 19, 20 |
| The stress modes | Compile failures, the tier 2 exit schedule, and the checksum of the code. | 21, 35 |
| `Debug` and `ReleaseSafe` runs | The Zig safety checks find a bad index or a bad union read in the helpers and in the compiler. | 21 |
| `tools/jit-perf.sh` | The instruction count of each benchmark is at or below its gate. | 17, 24, 25, 36 |
| `tools/kostya.sh` | The outside programs end with the output of `tclsh`, and each ratio is at or below its gate. | 6, 9, 25 |

### Performance gates

Each gate is an instruction count (`perf stat -e instructions:u`) of the whole process on x86-64 Linux, `ReleaseFast`, with `--jit`. A gate is the estimate plus a margin of about 15 %. If a gate fails, the implementer reports the measured count and the cause, and the reviewer and the user decide. A gate changes only with a recorded reason. The tier 2 gates are provisional until task 32 measures a model of each loop.

| Script | Today | After milestone 1 | After milestone 2 | After tier 2 |
|---|---|---|---|---|
| `sum.tcl` | 296.8 M | 110 M | 110 M | 16 M |
| `fib.tcl` | 163.3 M | 125 M | 112 M | 112 M |
| `nested.tcl` | 344.7 M | 165 M | 135 M | 100 M |
| `strbuild.tcl` | 328.9 M | 270 M | 270 M | 270 M |
| `foreach.tcl` | 211.5 M | 110 M | 88 M | 45 M |
| `dict.tcl` | 282.7 M | 230 M | 215 M | 215 M |
| `dictgrow.tcl` | 628.3 M | 580 M | 580 M | 580 M |
| `readloop.tcl` | 213.9 M | 165 M | 150 M | 150 M |

### Cost limits

| Cost | Limit |
|---|---|
| Each benchmark with the JIT in the build and off at run time | At most 1 % above the count of today. |
| Each benchmark with `-Djit=false` | At most 0.2 % above the count of today. |
| Startup (`puts hi`) with the JIT off | At most 5000 instructions above 0.70 M. |
| Startup with `--jit` | At most 50 000 instructions above 0.70 M. The region is reserved at the first compile. |
| Compile time of tier 1 | At most 400 machine instructions for one bytecode instruction. |
| Code size of tier 1 | At most 96 bytes for one bytecode instruction, as a mean over the eight benchmarks. |
| JIT memory | At most `jit_mem_limit` (16 MiB by default) for the region and all JIT data of one interpreter and its children. A function uses whole pages on Linux, Windows, and an Intel Mac. |
| Size of the runner binary | At most 200 KiB more for one backend. |
| Native stack of one proc call level | At most the stack that the interpreter uses for the same call. |

## Risks

- **The collector is a larger change than tier 1.** It replaces the base of all memory. A missed root is a use after free that a script can reach. The stress mode is the defense, and the collector has its own part in the review checklist.
- **A conservative collector can keep dead memory.** A number that equals an address keeps a block. The memory limit still bounds the script.
- **The collector changes when a value of the embedder is valid.** zslice must follow the new rule before it updates ztcl.

- **The layout of Zig unions.** A new Zig version can move a tag. The probe finds each layout of the form "payload, then a tag byte". Another form turns the JIT off. A test fails when the probe fails on a supported target, so a Zig update shows it.
- **Two implementations of one instruction.** An inline fast path can differ from the interpreter. The differential tests and the fuzzer are the defense. Each fast path is small, and each slow path is shared.
- **The helper refactor of `vm.zig`.** Moving the slow paths to named functions can change the code of the interpreter. The 1 % limit above catches it.
- **Ports that the author could not run.** Each fact about macOS, Windows, and arm64 in this page is from documentation. The first task of each port is a test of the memory calls on a real machine.
- **Tier 2 is the largest part and helps the fewest scripts.** Its gain is real only for loops of numbers. The tasks put it last, and the user can stop before it.
- **Indirect branch tracking.** If a system enforces IBT or BTI on JIT pages, each entry needs a landing pad. No target of this plan enforces it for such pages today. The author did not test this.
- **A JIT in a sandbox raises the cost of each bug.** A wrong template is a memory safety bug that a script can reach. This is the reason for the default of off.

## Open decisions for the user

0. **The collector. Decided.** The user chose the conservative mark-and-sweep heap that does not move a block, with the `hold` rule for a value from `eval`. Milestone 0 replaces the arena with it. It changes three rules: a value from `eval` is valid only until the next call, the place of the memory error is exact only with the collector off, and an allocation costs a little more.
1. **The order after milestone 2.** The plan does the ports before tier 2, because zslice runs on macOS and Windows. The other order gives the large gain for number loops on Linux first.
2. **Tier 2 at all.** Tier 2 gives about 20 times for `sum.tcl` and no gain for strings, dicts, and proc calls. The scripts of zslice decide its value. A profile of real zslice scripts is the input for this decision.
3. **The default.** The plan keeps the library option off in each case, and lets the runner flag default to on after the condition above. The other choice is off everywhere.
4. **The JIT memory limit.** 16 MiB, outside `mem_limit`, so that a script gives the same result in both modes. The other choice counts it in `mem_limit`, and a script near the limit then stops at a different place with the JIT on.
5. **The entitlement on macOS. Decided.** zslice gets `com.apple.security.cs.allow-jit` to use the JIT under the hardened runtime. A build with no entitlement keeps the JIT off on macOS.
6. **The write allowlist on macOS.** `pthread_jit_write_with_callback_np` is more work and a stronger limit.
7. **Unwind tables on Windows.** The plan registers them. The other choice is less code, and a crash handler of the embedder then fails inside JIT frames.
8. **Procs with no frame.** A proc such as `fib` could run with its parameters in registers and make its frame only at an exit. This is the one way to a large gain for `fib.tcl`. It is a large and risky change, and it is not in the tasks.
9. **Work on the interpreter and on the helpers.** Shorter handlers help each platform, also WebAssembly. A list cache with no compare, a cheaper frame, and a hash for integer keys help the four benchmarks that the JIT helps least. Each one is separate from this plan.
10. **Machines for the ports.** The acceptance tests of the ports need an Apple silicon Mac, an Intel Mac, a Windows x86-64 machine, and an arm64 Linux machine or an emulator.
