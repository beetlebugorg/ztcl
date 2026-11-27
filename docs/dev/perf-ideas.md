# Performance ideas

This page ranks 12 changes that make ztcl faster. Each one has a measure, a cause in the code, a design, the expected gain, the risk, and the checks. The page changes no code. Each idea has an issue, and the issue has the same text.

[perf-review.md](perf-review.md) has the earlier review. Its 10 findings are done and are not on this page.

## Method

- Date: 2026-11-26. Commit: `cb80459`. Machine: Intel Core i7-6700K, x86-64 Linux. Zig 0.17.0. `tclsh` is 8.6.16.
- Build: `zig build -Doptimize=ReleaseFast`.
- The scripts are in [`bench/ideas/`](../../bench/ideas). The output of each script is equal in ztcl and in `tclsh`.
- Instruction counts are `perf stat -e instructions:u` of the whole process, in millions. `bench/ideas/count.sh` prints the count for the interpreter, for `--jit --jit-tier2`, and for `tclsh`. Instruction counts do not change with the load of the machine.
- Wall times are from `clock microseconds` around one call, one run. Seven other jobs shared the machine, so a wall time can be wrong by 50 %. A decision uses a wall time only when the ratio is above 3.
- Profiles are `perf record -e instructions:u` or `-e cycles:u` and `perf report --no-children`.
- User time, system time, page faults, and the largest resident size are from `getrusage` of the child process.

```sh
bench/ideas/count.sh bench/ideas/pq.tcl          # one script
bench/ideas/count.sh -p m_dictlit                # one proc of micro.tcl
bench/ideas/count.sh -c 'dict get $d b'          # 1,000,000 passes of one command
zig-out/bin/ztcl --allow clock bench/ideas/inplace.tcl
```

## The picture

### Whole scripts

Instructions in millions, and the time of the interpreter.

| Script | Interpreter | `--jit --jit-tier2` | tclsh 8.6.16 | ztcl user s | ztcl system s | Page faults ztcl | Page faults tclsh |
|---|---|---|---|---|---|---|---|
| `pq.tcl` | 826 | 633 | 1,294 | 0.132 | 0.081 | 42,325 | 1,206 |
| `csv.tcl` | 3,467 | 3,060 | 3,665 | 0.433 | 0.051 | 26,114 | 7,551 |
| `wordfreq.tcl` | 1,295 | 1,101 | 2,168 | | | 12,582 | 8,379 |
| `tmpl.tcl` | 1,090 | 1,056 | 3,001 | 0.122 | 0.029 | 17,713 | 1,341 |
| `logparse.tcl` | 15,903 | 15,727 | 23,415 | | | 13,350 | 3,085,266 |
| `oo.tcl` | 1,641 | 1,449 | 2,928 | | | 4,296 | 280 |
| `structs.tcl` (first form, one sort with `apply`) | 13,671 | 13,575 | 2,488 | 2.411 | 0.642 | 359,904 | 70,679 |

Three facts come from this table.

- The JIT removes 3 % to 23 % of the instructions of these scripts. It removes 80 % to 95 % of the instructions of `bench/sum.tcl` and `bench/dsum.tcl`. These scripts spend their instructions in commands, in the collector, and in copies, and the JIT does not change those parts. So the first 10 ideas are changes to the interpreter and the heap. They also help the WebAssembly build, which has no JIT.
- ztcl uses fewer instructions than `tclsh` on `pq.tcl` and runs it more slowly (265 ms against 139 ms). The cause is the kernel time and the copies (ideas 1 and 3).
- `structs.tcl` is 5.5 times slower than `tclsh`. The cause is `apply` (idea 2).

### One command

Instructions for one pass of a loop of 1,000,000 passes, less the empty loop (151 for the interpreter, 19 for the JIT, 336 for `tclsh`). The variable `a` is `hello`, `d` is the literal `{a 1 b 2}`, and `l` is the literal `{1 2 3}`.

| Command | Interpreter | JIT | tclsh |
|---|---|---|---|
| `info exists a` | 1,149 | 1,156 | 81 |
| `dict get $d b` | 1,378 | 1,376 | 304 |
| `dict size $d` | 1,153 | 1,160 | 981 |
| `lindex $l end` | 1,085 | 1,043 | 147 |
| `lindex $l 1` | 593 | 549 | 147 |
| `lrange $l 0 1` | 801 | 793 | 68 |
| `llength $l` | 523 | 522 | 201 |
| `string trim $a` | 479 | 487 | 4,399 |
| `string compare $a world` | 439 | 437 | 396 |
| `expr {$i * 2 + 1}` | 110 | 2 | 388 |

Instructions for one call, from a loop of 200,000 calls, less the empty loop.

| Call | Interpreter | JIT | tclsh |
|---|---|---|---|
| `add $s $i` (a proc) | 560 | 386 | 2,302 |
| `apply $lam $s $i` | 9,383 | 10,772 | 2,605 |
| `uplevel 1 [list add 1 $i]` | 5,611 | 5,483 | 4,431 |
| `eval $cmd $i` (`cmd` is `[list add 1]`) | 119,197 | 154,761 | 17,150 |
| `regexp {l+} hello` | 4,058 | 4,074 | 2,658 |

### `micro.tcl`

The procs of `micro.tcl` where ztcl uses more instructions than `tclsh` (millions, 200,000 passes):

| Proc | Interpreter | JIT | tclsh | Ratio | Idea |
|---|---|---|---|---|---|
| `m_dictlit`: `dict get` on a dict from a literal | 1,290 | 1,258 | 327 | 3.94 | 6 |
| `m_lsetnest`: `lset m $i $j $v` | 665 | 575 | 327 | 2.03 | 10 |
| `m_dictfor`: `dict for` | 177 | 180 | 92 | 1.92 | 8 |
| `m_info`: `info exists`, `info level` | 664 | 603 | 360 | 1.84 | 5 |
| `m_switch`: `switch -glob` | 743 | 697 | 426 | 1.74 | 6, 8 |
| `m_subst`: `subst` | 1,056 | 1,024 | 697 | 1.52 | 6 |
| `m_incrstr`: `incr` by items of `split` | 205 | 199 | 137 | 1.50 | 9 |
| `m_dictnest`: `dict set d $a $b $v` | 682 | 619 | 456 | 1.50 | 10 |
| `m_dblstr`: `expr` on items of `split` | 268 | 253 | 200 | 1.34 | 9 |
| `m_strmatch` | 491 | 427 | 380 | 1.29 | |
| `m_lindex2`: `lindex $l $i 1` | 457 | 423 | 357 | 1.28 | 6 |
| `m_arrayexists` | 577 | 552 | 488 | 1.18 | 5 |

The other 26 procs use 0.18 to 0.64 times the instructions of `tclsh`. They are in "Measures with no finding".

## Summary

The rank is the expected gain divided by the risk. "Order" gives the ideas that go first. The issues are #279 to #290, in the order of the rank.

| Rank | Idea | Largest measure | Risk | Order |
|---|---|---|---|---|
| 1 | Keep the pages of empty spans | 38 % of the time of `pq.tcl` is kernel time | Low | First |
| 2 | Keep the proc of a lambda, and run list arguments of `eval` and `uplevel` as words | `apply` is 17 times slower than `tclsh` in `lsort -command` | Low | Any |
| 3 | Reads that keep the ownership of a dict | `dict set` then `dict get` is 88 times slower than `tclsh` at 1,000 keys | Medium: verifier and helpers of the JIT | Before 4 and 10 |
| 4 | In-place writes to variables that are not slots | `dict set` on a namespace variable is 63 times slower at 1,000 keys | Medium | After 3 |
| 5 | Subcommand dispatch with a table and a site hint | `info exists` uses 1,149 instructions against 81 | Low | Any |
| 6 | Each list reader uses the parse cache, and a list keeps its text | `dict get` on a literal uses 1,378 instructions against 304 | Step 1 low, step 2 medium | Step 1 any, step 2 before 9 |
| 7 | Keep the regex DFA with the pattern, and add anchors to it | A match with no group is 2.8 times slower than `tclsh` | Medium | Any |
| 8 | Bytecode for `dict for` and for the reads of `dict` | `dict for` uses 1.92 times the instructions of `tclsh` | Low to medium: new instructions | After 3 |
| 9 | Keep the number of a list item that a script reads as a number | 13 % of `csv.tcl` is number parsing | Low to medium | After 6 step 2 |
| 10 | Ownership of inner lists and dicts | `dict lappend` is 11 times slower, `lset` with two indexes 4 times | High | After 3 and 4 |
| 11 | A faster mark, and a study of sticky mark bits | The collector has 10 % to 30 % of the cycles | Step 1 low, step 2 high | After 1 |
| 12 | A value of 16 bytes | A value has 24 bytes in each list, stack, and cell | High: each tag check of the JIT | Last, after the JIT ports |

## The rules that each idea keeps

Each idea states how it keeps these rules. The words below are the short names.

- **Same output and count:** the output and the count of compute units are equal with the JIT on and off (`tools/jit-diff.sh`, also with `--stress`).
- **Deterministic units:** the count of compute units is a function of the script alone. No count reads a clock, an address, or the state of a cache.
- **Tcl 8.6 semantics:** the string form of each value, the traces, and the reference semantics stay exact. A copy of a value never changes.
- **Size:** the budget of the WebAssembly library is 504 KB gzip. On commit `ccb35f9` (2026-11-27), `ztcl.wasm` has 506,014 bytes with `gzip -9`.
- **Review list:** [jit-review.md](jit-review.md) applies to each change of `src/jit/`.

The checks that each change runs, in this order: `zig build test`, `zig build test -Djit=false`, `tools/jit-diff.sh`, `tools/jit-diff.sh --stress`, `tools/suite.sh` and `tools/suite.sh -j`, `python3 -I tools/gc-fuzz.py` for a change of the heap or of ownership, `zig build jit-fuzz` for a change of the bytecode, `tools/jit-perf.sh --check off`, and `tools/size-report.sh --check`.

Other work is active in `src/jit/tier1_*.zig` and `src/jit/tier2_*.zig`. Ideas 1, 2, 4, 5, 6, 7, 9, and 11 do not touch `src/jit/`. Ideas 3, 8, and 10 add a helper and a verifier row and no template. Idea 12 changes each template.

## 1. Keep the pages of empty spans

### Evidence

| Script | User s | System s | Page faults | Largest resident size | tclsh system s | tclsh page faults |
|---|---|---|---|---|---|---|
| `pq.tcl` | 0.132 | 0.081 | 42,325 | 47 MB | 0.004 | 1,206 |
| `tmpl.tcl` | 0.122 | 0.029 | 17,713 | 52 MB | 0.006 | 1,341 |
| `csv.tcl` | 0.433 | 0.051 | 26,114 | 70 MB | 0.013 | 7,551 |
| `structs.tcl` | 2.411 | 0.642 | 359,904 | 1,412 MB | 0.101 | 70,679 |

`pq.tcl` allocates 465 MB in total (`--report --gc off` prints `mem=465410872`) and its live data is 7 MB (`--report` prints `mem=6960744`). The 42,325 page faults are 165 MB of first writes to a page, and the largest resident size is 47 MB. So the process maps the same amount of memory again after each collection.

### Cause

`sweep` (`src/heap.zig`) calls `freeSpan` for each span with no live block. `freeSpan` gives the pages to `h.backing`, and the allocator of the runner unmaps them. The next allocations call `newPage`, which maps new pages, and the kernel clears each page at the first write. A script with little live data frees almost each span at each collection, and a collection starts at each 16 MiB (`min_threshold`).

### Design

Keep the pages below the counter, so the count of bytes does not change.

1. Add a struct `Spare` to `Counting` (`src/interp.zig`). It has an array of 17 lists, one for each length from 4 KiB to 64 KiB in steps of 4 KiB (index `len / 4096`), a count of the bytes that it holds, and a limit `spare_max` (default 16 MiB, the value of `heap.min_threshold`).
2. A free block is a node of its list: the first 8 bytes of the block have the address of the next block.
3. In the `free` function of `Counting`: after the count goes down, when the alignment is 4 KiB, the length is a multiple of 4 KiB and at most 64 KiB, and `spare.bytes + len <= spare_max`, push the block on its list. In each other case call the child allocator.
4. In the `alloc` function of `Counting`: after the limit checks and the count, when the alignment is 4 KiB and the list of that length has a block, pop it and return it. In each other case call the child allocator.
5. `Interp.deinit` and `Interp.reset` give each spare block to the child allocator. `compact` does the same before it makes the new heap.
6. A child interpreter shares the heap of its root, so only the counter of the root has spare blocks.
7. In a build with safety checks, fill a spare block with `heap.dead_byte` after the link word, as `sweep` does for a dead block.

`pageBytes` gives 4 KiB to 64 KiB for each size class, so the 17 lists serve each small span. A large block keeps the path of today.

### Expected gain

Estimate: the system time of `pq.tcl` goes from 0.081 s to under 0.01 s, so the script runs about 30 % faster. `tmpl.tcl` gains about 15 % and `csv.tcl` about 8 %. A reused page is also in the cache of the processor, so the user time can go down. I did not measure a prototype.

### Risk and rules

- Low. The change is in one allocator wrapper.
- **Same output and count:** `Counting.used` has the same value at each point, because the count changes before the choice of the source of the block. So `memUsed`, the memory limit, and the trigger of the collector do not change. The JIT does not use this allocator.
- **Deterministic units:** no change.
- The process holds up to `spare_max` more bytes than its count. `docs/embedding.md` and `docs/limits.md` state it, and the embedder can set `spare_max` to 0.
- A reused page has old bytes. A new block is not clear today when its span has a freed block, so no code reads a new block as zero. Check with `--gc-stress 1` in a build with safety checks.
- WebAssembly: memory does not shrink there. Keep the same code, because the wasm allocator also does work for each span.

### Checks

`tools/mem-flat.sh`, `python3 -I tools/gc-fuzz.py`, the unit tests with `--gc-stress`, and `tools/jit-diff.sh` (it compares the memory count). Measure: the table above again.

## 2. Keep the proc of a lambda, and run list arguments as words

### Evidence

`bench/ideas/calls.tcl`, wall ms:

| Proc | ztcl | `--jit --jit-tier2` | tclsh |
|---|---|---|---|
| `apply $lam $s $i`, 200,000 calls | 565.7 | 658.6 | 57.8 |
| `apply {{a b} {...}} $s $i` | 661.4 | 791.1 | 55.6 |
| `{*}$cmd $s $i`, `cmd` is `[list apply {...}]` | 890.7 | 627.8 | 68.8 |
| `add $s $i` (a proc) | 22.3 | 12.7 | 50.2 |
| `uplevel #0 [list $cmd $s $i]` | 555.1 | 567.6 | 126.9 |
| `lsort -command {apply {...}}`, 20,000 items | 1,318.3 | 1,028.4 | 80.1 |
| `lsort -command cmpi`, 20,000 items | 55.3 | 31.6 | 66.1 |

One `apply` uses 9,383 instructions, and one proc call uses 560. `eval $cmd $i` uses 119,197 instructions against 17,150 in `tclsh`. In `structs.tcl`, the sort of 20,001 records with `apply` runs in 4,739.9 ms against 274.7 ms in `tclsh`, and the same sort with a proc runs in 193.0 ms against 465.7 ms.

### Cause

- `cmdApply` (`src/cmds.zig:518`) calls `makeProc` on each call. `makeProc` parses the parameter list and makes a new `Proc`, and the body compiles again. The profile of `structs.tcl` has 31 % in `memmove`, 25 % in the collector, and 7.5 % in `Parser.parseScript` and `parseParts`.
- `cmdEval` (`src/cmds.zig:881`) with more than one argument makes the text of the arguments with `concat` and compiles it. The text is new on each call, so `script_cache` gets a new entry on each call.
- `cmdUplevel` (`src/cmds.zig`, the lines after 237) uses `scriptOf` for one argument and `concat` for more. It has no list path.

### Design

Part A, the lambda cache:

1. Add `lambda_cache: std.AutoHashMapUnmanaged(SliceKey, *Proc)` to `Interp`, next to `script_cache` (`src/interp.zig:1054`). The key is the address and the length of the lambda value: the item slice of a list value, or the bytes of a string value. A tag bit in the key tells the two kinds apart.
2. In `cmdApply`: look up the key. On a hit, use the `Proc`. On a miss, call `makeProc`, set `p.ns` from item 2 as today, and put the `Proc` in the table.
3. Run the check of the namespace on each call, also on a hit, because a script can delete the namespace. The error of a bad lambda is not in the table, so the next call makes the error again.
4. Clear the table where `script_cache` is cleared: at a collection, at `reset`, and in `compact.zig`. A cleared table makes the address safe: between two collections no block is freed, so an address and a length name one value.
5. A list buffer that grows in place keeps its address. A lambda is a list of 2 or 3 items, and the key has the length, so a longer view is a different key. An `lset` in place on a cell that owns the list changes the items under the same key. So `cmdApply` does not use the cache for a list whose `ListObj` has `used` above the length of the view, and `more.lsetOwned` on a list of 3 items or fewer removes its key.
6. The `Proc` now lives across calls, so its `Code` keeps its JIT state and its call count. Check `beginProcBody` and `endProcBody` for a use of the `Proc` after the call.

Part B, lists as words:

1. In `cmdEval`, when each argument is a list value (the tag `.list`), copy the items of each argument to one buffer and call `it.evalWords`. A string argument uses the path of today.
2. In `cmdUplevel`, when the script is one list value, or each argument is a list value, call `evalWords` in the target frame.
3. `evalWords` already makes the text of the list for the error trace only when an error occurs.

### Expected gain

Estimate: `apply` goes from 9,383 instructions to about 700 (a proc call plus the lookup). `structs.tcl` goes from 3.65 s to under 0.7 s. `eval $cmd $i` goes from 119,197 instructions to about 800. I did not measure a prototype.

### Risk and rules

- Low. Part A copies the pattern of `script_cache`. Part B copies the path that `cmdEval` has for one list.
- **Same output and count:** the paths are in commands that both modes call. **Deterministic units:** the count of compute units of `apply` must not depend on a hit. Find each unit that `makeProc` and the compile use (the parse of the parameters), and charge the same units on a hit, or move the charge to a place that both paths run. For Part B, `evalWords` and the text path can use different counts for the same call. Measure both with `--report`, and make `evalWords` charge the count of the text path, as the list path of `eval` did in finding 2 of `perf-review.md`.
- **Tcl 8.6 semantics:** `apply` with a lambda that changes (a new string at the same variable) gets a new key. `info frame`, `info level`, and `errorInfo` must be equal to today: compare with the tests `apply.test`, `uplevel.test`, and `eval.test` of the suite.

### Checks

`tools/suite.sh -t apply`, `-t uplevel`, `-t eval`, `-t lsort`, with and without `-j`. `tools/jit-diff.sh`. Measure with `bench/ideas/calls.tcl` and `bench/ideas/structs.tcl`.

## 3. Reads that keep the ownership of a dict

### Evidence

`bench/ideas/inplace.tcl`, a dict of 1,000 keys or a list of 1,000 items, 50,000 passes, wall ms:

| Proc | The loop body | ztcl | tclsh | Ratio |
|---|---|---|---|---|
| `d_setonly` | `dict set d $k $i` | 8.3 | 18.7 | 0.4 |
| `d_setget` | `dict set d $k $i; incr s [dict get $d $k]` | 2,120.4 | 24.0 | 88.4 |
| `d_setexists` | `if {[dict exists $d $k]} {dict set d $k $i}` | 2,117.1 | 24.1 | 87.8 |
| `d_incrget` | `dict incr d $k; incr s [dict size $d]` | 1,783.3 | 32.2 | 55.4 |
| `l_setget` | `lset l $k $i; incr s [lindex $l $k]` | 5.3 | 15.1 | 0.4 |
| `l_setpass` | `lset l $k $i; incr s [peek $l $k]` (a proc) | 217.7 | 32.7 | 6.7 |

The time of `d_setget` grows with the size of the dict: each pass copies the 2,000 values of the buffer.

### Cause

A cell owns its dict or list (`Var.v == .owned`, `src/interp.zig:441`), and `dict set` then writes in place (`opDictUpdateDrop`, `src/vm.zig`). Each general read of the cell ends the ownership (`loadSlow`), because the read puts a second holder of the buffer on the stack. The next write copies the buffer (`dict.setIn`). `llength $v` and `lindex $v $i` keep the ownership: `compileAccess` (`src/vm.zig:685`) loads the variable with `x` 1 and the `access` instruction reads it at once. `dict get`, `dict exists`, and `dict size` have no such form, so they go through `load` and `invoke`.

### Design

Add three forms to the enum `Access` (`src/vm.zig`): `dict_get`, `dict_exists`, and `dict_size`.

1. In `compileAccess`: accept `dict get $v key`, `dict exists $v key`, and `dict size $v`, with a literal subcommand and exactly one key word. The rule of `peekable` applies: the dict word is one plain variable, and the key is a literal or one plain variable. A form with more keys, or with another word kind, compiles as today. The guard of the inline forms needs the name `dict` (see how `dict incr` and `dict set` register it in `inline_names`).
2. Emit `load` with `x` 1 for the variable when the code is a proc body (`!c.named`), then the key word, then `access` with the new form. In a script outside a proc, emit a plain load and the same `access`.
3. Add `opDictGet`, `opDictExists`, and `opDictSize` next to `opLlength`. Each one calls a new public function of `src/dict.zig` that `cmdDict` also calls for the same subcommand (`getIn` with one key, the `exists` branch, the `size` branch). So the result, the error text, and the error code are those of the command. `opDictGet` replaces the two stack values with the result, and `sp` goes down by one, as for `lindex`.
4. The compute units: `invoke` uses one unit and `access` uses the unit of its `guard`. Read `opLindex` and its compile to see how `lindex` kept the count of the command path, and do the same. The probe of `dict.lookup` keeps its own units.
5. The JIT: add the three forms to `accessHelper` (`src/jit/tier1_x64.zig` and `tier1_a64.zig` send each form with no template to a helper), add the wrappers in `src/jit/helpers.zig`, and add the verifier rows in `src/jit/verify.zig` (the stack effect of each form). Tier 2 gives the kind `any` to the result. No template changes.
6. The result of `dict get` is an item of the buffer. It is a copy of a `Value`, so it does not hold the buffer of the dict. An item that is a list holds its own `ListObj`. Idea 10 must end the inner ownership on this read.

Then the same forms for the reads that return no part of the buffer and run no script: `dict keys $v` with no pattern and `dict values $v` (each makes a new list), `lsearch $v x` with no option, `lrange $v a b` only if `cmdLrange` copies the items (check: a prefix view of the same `ListObj` holds the buffer, so it must copy or end the ownership), and `$x in $v` in `expr`.

### Expected gain

`d_setget`, `d_setexists`, and `d_incrget` then do the work of `d_setonly` plus one lookup: an estimate of 15 ms to 25 ms in place of 2,120 ms. `pq.tcl` has this pattern on a dict of 14,400 keys (`dict set dist $k $nd` and `dict get $dist $k`). I did not measure a prototype.

### Risk and rules

- Medium. The change adds forms to an instruction that the JIT knows, so it needs helper wrappers and verifier rows on each target. Coordinate through `questions.md` with the work on the code generators, and keep the JIT part in its own commit.
- **Tcl 8.6 semantics:** the rule of today stays: between the load and the access, only loads of plain variables run, and the guard turns the form off while a variable has a trace. So no script runs while the stack holds the owned buffer. A key word that is a command or an array element does not get the form.
- **Same output and count:** `tools/jit-diff.sh` must pass with the new forms in `tests/jit/owned_lists.tcl`. Add cases: a copy of the dict in another variable before the write, `upvar`, a trace that starts between two passes, an error of a missing key, and a key that is the variable of the dict.

### Checks

`zig build jit-fuzz` with the new forms in its generator, `tools/jit-diff.sh --stress`, `tools/suite.sh -t dict` with and without `-j`. Measure with `bench/ideas/inplace.tcl` and `bench/ideas/pq.tcl`.

## 4. In-place writes to variables that are not slots

### Evidence

`bench/ideas/inplace-names.tcl`, 1,000 keys or items, 50,000 writes, wall ms:

| Case | ztcl | tclsh | Ratio |
|---|---|---|---|
| `dict set D ...` at the top level | 1,630.3 | 60.1 | 27.1 |
| `lset L ...` at the top level | 161.7 | 34.5 | 4.7 |
| `dict set ::D ...` in a proc | 1,703.6 | 27.2 | 62.6 |
| `dict set a(x) ...` in a proc | 1,674.4 | 25.4 | 65.9 |
| `lset a(x) ...` in a proc | 184.7 | 6.5 | 28.4 |
| `lappend a(x) $i` in a proc | 12.3 | 5.0 | 2.5 |
| `global D; dict set D ...` in a proc | 3.9 | 9.2 | 0.4 |
| `dict set d ...` in a method, `d` an object variable | 9.4 | 8.8 | 1.1 |

### Cause

Only the bytecode of a proc slot makes and uses an owned cell (`opDictUpdateDrop` and `lsetOp` read `f.vars.items[i.a].cell`). The comments at `src/vm.zig:760` and `:780` say "Slots of a proc only: a named cell has no owned form". A name with `::`, a name at the top level, and an array element go to `dict.cmdDict` or `more.cmdLset`, and these copy the buffer on each write. A global cell can already be owned today: `global D` links the slot to the global cell, and `Var.target` follows the link.

### Design

Step 1, cells by name:

1. In `more.cmdLset`, `lsetPlain` already finds the cell by name and calls `lsetOwned`. It then ends the ownership because the command returns the list. Add a parameter "the result is not used", and keep the ownership in that case. `lset_drop` on a named variable passes it. For the `invoke` path, the compiler knows when a command is a statement whose result is dropped: add a flag to the site (`Cmd`) and set it in the compile of a statement.
2. In `dict.cmdDict`, for `set`, `incr`, `append`, `lappend`, and `unset`: find the cell with `findVar`. When the cell is `.owned` and the dict has its mark, call `updateOwned` (for `set` and `incr`) and return. After a general write that made a new buffer, set the cell to `.owned` when the result is dropped, as `opDictUpdateDrop` does.
3. For the bytecode of a script outside a proc (`named` is true): let `dict_update_drop` and `lset_drop` find the cell with `writeCell` in place of `f.vars.items[i.a]`, and remove the limit to slots.
4. Each general read ends the ownership through `Var.settle` or `readRef`. Check each reader of a named cell: search `src/` for `.v.val` and `.v == .val` in code that gets a cell from `findVar`, `slotCell`, or a namespace table, and make each one handle `.owned` or call `settle`.

Step 2, array elements:

1. `ArrayMap` is `std.StringArrayHashMapUnmanaged(Value)`, so an element has no cell. Add one field to the array: the index of the one element that the array owns, or none. Wrap the map in a struct with this field, or keep the field in the `Var` of the array.
2. A write in place is valid when the element is the owned one. Each read of an element, each `array get`, `array names` with values, a trace, and a link to the element clear the field first. `lset a(x)`, `dict set a(x)`, and `lappend a(x)` set it after a write that made a new buffer.

### Expected gain

The cases of the table reach the times of the slot forms: an estimate of 5 ms to 15 ms in place of 160 ms to 1,700 ms.

### Risk and rules

- Medium. A reader that does not end the ownership gives a script a value that changes later. That is a wrong result, and it is not a memory error.
- **Tcl 8.6 semantics:** the ownership rule of `design.md` stays: an owned buffer is never in another place. `tests/jit/owned_lists.tcl` has the cases for slots. Add the same cases for a top-level variable, a namespace variable, and an array element: a copy in another variable, in a list, in a dict, and in an array, `upvar`, `global`, `variable`, a trace, `info exists`, `array get`, `unset`, a coroutine, a child interpreter, and a thread (`thread.share` copies the value).
- **Same output and count:** the general commands are the same code in both modes. The count of compute units of a write must not depend on the ownership: the copy path and the in-place path must use the same units. Check `dict.setIn` for units that depend on the copy.

### Checks

`python3 -I tools/gc-fuzz.py`, `tools/jit-diff.sh --stress`, `tools/suite.sh -t dict -t lset -t var -t trace -t namespace -t upvar` with and without `-j`. Measure with `bench/ideas/inplace-names.tcl`.

## 5. Subcommand dispatch with a table and a site hint

### Evidence

| Command | Interpreter | tclsh |
|---|---|---|
| `info exists a` | 1,149 | 81 |
| `string trim $a` | 479 | 4,399 |
| `string compare $a world` | 439 | 396 |

The profile of the `info exists` loop: `mem.eqlBytes` 39.1 %, `cmds.cmdInfo` 33.9 %, `vm.exec` 18.6 %. The profile of the `string trim` loop: `vm.exec` 36.5 %, `cmds.cmdString` 25.8 % (about 160 instructions), `trimChars` 15.5 %, `Interp.str` 10.1 %. In `wordfreq.tcl`, `cmdString` has 13.0 %. In `tmpl.tcl` it has 13.8 %.

### Cause

- `cmdInfo` (`src/cmds.zig:2204`) compares the subcommand with each name of `info_names` (an equal test and a prefix test for each one). It then compares the name with a string literal in a chain of `if` statements, and `exists` is far down the chain.
- `cmdString` (`src/cmds.zig:1581`) uses `std.meta.stringToEnum` on each call.
- Each call builds an argument slice, converts the subcommand word to a string, and checks the argument count again.

### Design

Step 1, `cmdInfo`: make an enum of the subcommands, find it with `std.meta.stringToEnum` and then `uniquePrefix`, as `cmdString` does, and dispatch with one `switch`. Keep the texts of the errors.

Step 2, a site hint for each native ensemble (`string`, `info`, `dict`, `array`, `namespace`, `clock`, `file`, `chan`, `binary`, `encoding`):

1. Add two fields to `Cmd` (`src/interp.zig:74`): `sub_fn: usize` (the address of the command function that wrote the hint, 0 for none) and `sub: u16`.
2. A helper `subOf(comptime Sub, it, argv, cmd, self)`: when `cmd` is not null, `cmd.words[1].kind == .lit`, and `cmd.sub_fn == self`, return `cmd.sub`. In the other case find the subcommand by name and write the hint when the word is a literal.
3. The hint depends only on the text of a literal word and on the function. A `rename` gives the site another function, and the address check fails. So the hint needs no epoch.

Step 3: compile `info exists name` with a literal plain name to an instruction that tests the slot. `tclsh` uses 81 instructions for it. This step adds an instruction, so it needs a helper and a verifier row, and it goes with idea 8.

### Expected gain

Estimate: `info exists` goes from 1,149 to about 250 instructions with steps 1 and 2. Each `string` call loses about 100 of its 160 dispatch instructions, so `wordfreq.tcl` and `tmpl.tcl` gain 5 % to 8 %.

### Risk and rules

- Low. Steps 1 and 2 change no bytecode and no JIT code.
- **Tcl 8.6 semantics:** an unknown or ambiguous subcommand gives the error of today. A prefix (`info exi`) still works. Check with `tools/suite.sh -t info -t string`.
- **Deterministic units:** the dispatch uses no compute unit today. Check `cmdInfo` for a unit in the name loop before the change.

## 6. Each list reader uses the parse cache, and a list keeps its text

### Evidence

| Command, on a variable that holds a literal | Interpreter | tclsh |
|---|---|---|
| `dict get $d b` | 1,378 | 304 |
| `dict size $d` | 1,153 | 981 |
| `lindex $l end` | 1,085 | 147 |
| `lrange $l 0 1` | 801 | 68 |
| `llength $l` | 523 | 201 |

Profiles: `value.Value.asList` has 29.8 % of `m_dictlit`, 34.4 % of `m_switch`, 40.4 % of the `lindex $l end` loop, and 26.9 % of the `dict size` loop. `Heap.alloc` has 8.6 % to 19.5 % of the same loops. `m_subst` has 20.2 % in `Heap.alloc` and 14.4 % in the parser.

### Cause

A string value has no second form. `Value` is a tagged union, and the tag `.str` has only the bytes (`src/value.zig:17`). Each command that reads a string as a list calls `Value.asList`, which parses the text and allocates the items. `Interp.readList` (`src/interp.zig:1813`) keeps 16 parses, for `llength` and `lindex` only, for a string of 32 bytes or more, from its second read. A cell with the canonical text of an integer gets the integer (`shimmer`, `src/vm.zig:1321`). A list has no such step, because a `.list` value has no place for its text, and the string form of the parsed list can differ from the text (`{a  b}` has two spaces).

### Design

Step 1, a wider cache:

1. Make `Interp.list` (`listSlow`) use the cache of `readList` for each string. So `dict`, `lrange`, `lsearch`, `foreach`, `switch`, `lsort`, `join`, and `concat` get it.
2. Use 256 places in place of 16, and enter a string of any length at its second read. Measure the miss cost on `bench/readloop.tcl`.
3. Add the same table for the template of `subst` (the parsed parts), keyed by the address and the length of the string.

A reader that writes to the items must not get the slice of the cache. `Value.toList` and `ownList` copy today. Check each caller of `it.list` that casts the constant away (`@constCast`).

Step 2, the text of a list. This step gives a list value the two forms of a Tcl object.

1. Add `text: []const u8 = ""` and `text_len: usize = 0` to `ListObj` (`src/value.zig:170`). `text` is the string form of the view of `text_len` items. It is valid when `text.ptr` is set.
2. `listToString` for a list value returns `obj.text` when `l.len == obj.text_len`. In the other case it makes the string, and stores it when the view is the whole used part (`l.len == obj.used`).
3. Each write in place clears the text: `List.append` in place, `lsetOwned`, `dict.updateOwned`, `dict.appendPair` in place, and the inline `lappend` of the JIT. The JIT template writes `used` today. It must also clear `text.ptr`, or the append path must make `text_len` differ from each view: an append makes a longer view, and the text is for the shorter view, so the text stays valid for the old view. Only a write to an item inside the view (`lset`, `dict set` of an existing key) needs the clear, and those are helpers. So no template changes.
4. A new function `Interp.asListValue(v)` makes a list value from a string: it parses the text and sets `text` to the string and `text_len` to the item count. The string form of this list is the exact text of the script.
5. Use it to change the holder: when `access` with `llength` or `lindex`, a `dict` read, or `foreach_init` reads a slot whose cell is `.val` with a `.str` that parses as a list, store the list value in the cell. This is `shimmer` for lists. A literal of the code (`code.lits`) can get the same change, because the string form stays the exact text.
6. `head_places` grows from 2 to 3 values, so a list uses 24 bytes more. Measure the memory of `bench/ideas/structs.tcl` before and after.

### Expected gain

Estimate for step 1: `dict get $d b` goes from 1,378 to about 450 instructions, and `m_dictlit` from 1,290 M to about 450 M. Step 2 removes the cache lookup and the check of the dict mark on each read, and it lets tier 2 see a list in the cell. `m_switch` needs idea 8 too.

### Risk and rules

- Step 1 is low. Step 2 is medium: a missed clear of the text gives a wrong string form.
- **Tcl 8.6 semantics:** the string form of a value that came from a string stays the exact string. That is the reason for `text`. Test: `set l "a  b"; llength $l; puts $l` must print two spaces. Test a string that is a list and a script (`eval $l` after `llength $l`), a dict with a duplicate key (`dict get` reads the last value, and the string form keeps both), and each write in place followed by a read of the string form.
- **Same output and count:** the count of compute units must not depend on a cache hit. The parse of a list charges units today (check `parseList` and its callers). On a hit, charge the same units, as the regex DFA does for its ticks.
- **Size:** the code of step 2 is small. Check with `tools/size-report.sh --check`.

### Checks

`tools/suite.sh -t list -t dict -t string -t lindex -t lrange -t switch -t subst` with and without `-j`, `tools/jit-diff.sh --stress`, `python3 -I tools/gc-fuzz.py` (the cache holds slices, and a collection must clear it).

## 7. Keep the regex DFA with the pattern, and add anchors to it

### Evidence

`bench/ideas/regexp.tcl`, 20,000 matches on one log line of 85 bytes, wall ms:

| Case | ztcl | tclsh |
|---|---|---|
| `full`: `^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+)` | 458.9 | 1,591.0 |
| `nocap`: the same pattern with no group, no match variable | 156.6 | 56.9 |
| `two`: `(\d+) (\d+)$` | 101.8 | 99.0 |
| `simple`: `"(\S+) (\S+)` | 182.3 | 109.2 |
| `kv`: `^(\w+)=(.*)$` on a short string | 79.2 | 96.7 |

`nocap` uses 7.8 microseconds for 85 bytes, about 90 ns for each byte. `regexp {l+} hello` uses 4,058 instructions against 2,658. The profile of `logparse.tcl`: `Matcher.dissect` 31.8 %, `addThread` 15.4 %, the hash map of `re_memo` 14.8 %, the append of a thread 5.5 %, `search` 5.4 %, `catFrom` 4.9 %.

### Cause

- The lazy DFA is a field of the `Matcher` (`dfa: ?*Dfa`, `src/regex.zig:1229`), and `runDfa` makes it on each call of `regexp`. Each state allocates a table of 256 entries. So a short match builds its states and uses each one a few times.
- `dfaOk` (`src/regex.zig:256`) refuses a program with an assert. `^` and `$` are asserts, so an anchored pattern runs the thread simulation.
- The groups come from `dissect`, which tries each split of a concatenation and keeps the failed spans in the hash map `it.re_memo`.

### Design

Step 1, keep the DFA:

1. Move `dfa` from `Matcher` to the compiled pattern (`Regex`, the struct that `compile` fills at `src/regex.zig:1162`). The compiled pattern is in the regex cache of the interpreter, so the states live across calls.
2. A state depends on the thread list alone, and a transition keeps its ticks, so a kept state gives the ticks of today. The limit of 64 states stays, for each pattern in place of each call. When the limit is reached, the search uses the simulation for the rest, as today.
3. The memory of the states is in the heap. Clear the DFA when the cache drops the pattern, and at a collection if the regex cache is cleared there.

Step 2, anchors:

1. Let `dfaOk` accept `^` and `$` (the asserts of the start and the end of the text, and of a line with `lineanchor`). An assert has no character, so its result depends on the position: at the start, at the end, after a newline, before a newline.
2. Resolve the asserts when a state is made: the closure of the threads (`addThread`) runs with the context of the position. Give a state a context key: `at_start`, `after_newline`, or `other`. The end assert needs the next character, so make the transition on a character with a second variant for "this is the last character" (and for "the next character is a newline" with `lineanchor`).
3. Word asserts (`\m`, `\M`, `\y`) and lookahead keep the simulation.

Step 3, the groups:

1. Replace the hash map `re_memo` with a bit table when `nodes * (n + 1) * (n + 1)` is small (a text of 256 characters or fewer), indexed by the node, `lo`, and `hi`.
2. In `catFrom`, a part that is a run of one character class followed by a literal character (`(\S+) `, `[^"]*"`) has one valid split for a greedy run when the class does not accept the literal: the end of the run. `runEnd` gives it. Check this case before the general loop over the splits.
3. A later step: one small DFA for each node that answers "does this node match exactly the span", so `catFrom` tries only the splits that the DFA accepts.

### Expected gain

Estimate: step 1 and step 2 bring `nocap` from 156.6 ms to under 40 ms, and each short `regexp` call from about 4,000 instructions to under 1,500. Step 3 part 2 removes most of the 300 ms that `full` adds to `nocap`. I did not measure a prototype.

### Risk and rules

- Medium. The matcher has the rules of Tcl for the longest and the shortest match.
- **Deterministic units:** the ticks of a search must be equal to today. Steps 1 and 2 keep the ticks in the transitions. Step 3 changes the work of `dissect`, and `dissect` counts a tick for each call. Add the ticks of the skipped splits, as the literal scan of finding 6 of `perf-review.md` does, or accept a new count and record it in the PR. The count must not depend on the state of a kept DFA: a transition gives the same ticks on its first use and on each later use.
- **Tcl 8.6 semantics:** `tools/suite.sh -t regexp -t regexpComp -t reg` must give the counts of today. The script of 20 patterns of finding 6 gives 410,308 compute units on main, and it must give the same number.

## 8. Bytecode for `dict for` and for the reads of `dict`

### Evidence

`m_dictfor` uses 177 M instructions against 92 M in `tclsh`. Its profile: `Interp.findVar` 39.8 %, `vm.exec` 24.8 %, `Interp.setVar` 13.7 %, `vm.runFull` 9.4 %. `m_switch` (`switch -glob` with four patterns) uses 743 M against 426 M, with 34.4 % in `Value.asList` and 6.5 % in `Heap.alloc`. `m_dictfor` gets no gain from the JIT (180 M).

### Cause

`dict for` runs `cmdDict`, which sets each loop variable by name with `setVar` and runs the body as a script on each pass. `foreach` and `lmap` compile to `foreach_init` and `foreach_next`. `switch` compiles only for exact patterns. With `-glob`, the command parses the list of patterns and bodies on each call.

### Design

1. `dict for {k v} $d body` with two literal plain names and a literal body: compile it with the loop of `compileForeach`. `foreach_init` reads the pairs of the dict (the items of the checked dict value, as `foreach {k v} $d` reads them) after a check that the value is a valid dict. A dict with a duplicate key in its string form needs the pairs of `dict.pairs`, so `foreach_init` gets a flag `x` for "dict": it calls `dict.readPairs` and iterates the result with a step of 2. The error of a value that is no dict is the error of the command.
2. `break`, `continue`, and the result (an empty string) follow `foreach`. Tier 2 can then compile the loop.
3. `switch -glob` and `switch -regexp` with literal patterns and bodies: compile the bodies as `switch -exact` does, and replace `str_eq_jump` with a new instruction `match_jump` that calls `globMatch` (or the cached regex) on the top of the stack and the literal `a`. Start with `-glob`.
4. `dict exists`, `dict get`, and `dict size` on a value that is not a plain variable use the `access` forms of idea 3.
5. `info exists name`: see idea 5, step 3.

### Expected gain

Estimate: `m_dictfor` reaches the cost of `foreach` over pairs, about 60 M instructions in the interpreter and 25 M with tier 2. `m_switch` loses the 41 % of the list parse and its allocation.

### Risk and rules

- Low to medium. Each new instruction needs a verifier row, a helper, and a differential test (the review list, "The verifier and the entry"). `foreach_init` with a flag adds no instruction.
- **Same output and count:** the compute units of one pass of `dict for` in the command must equal the units of the bytecode loop. `lmap` had the same work (finding 3 of `perf-review.md`): read how it kept the count.
- **Tcl 8.6 semantics:** `dict for` reads the dict one time before the loop, and a change of the variable in the body does not change the loop. A trace on a loop variable runs on each pass.

## 9. Keep the number of a list item that a script reads as a number

### Evidence

`m_incrstr` uses 205 M instructions against 137 M, and `m_dblstr` 268 M against 200 M. In `csv.tcl`, `value.parseIntMode` has 5.7 %, `parseFloat` 4.1 %, and `value.parseDouble` 3.2 %: 13 % of the script. The canada reader of `docs/dev/values.md` has 12 % in `expr.num` and 5 % in `shimmer`.

### Cause

`split` makes string items. `expr` and `incr` parse the string on each read (`Value.asNumber`, `src/value.zig:54`). `shimmer` (`src/vm.zig:1321`) stores the integer in a cell, only for an integer, and only for a cell. A loop that reads the item again from the list (`lindex $row 2` in each pass, or a second `foreach`) parses it again.

### Design

1. Extend `shimmer` to a double: when the text of the cell is the canonical text of a double (`formatDouble` of the parsed number gives the same bytes), store the double.
2. `foreach_next` stores an item in the loop variable. When an operator then changes the cell to a number through `shimmer`, also write the number to the item of the list buffer when the buffer is the one that the loop holds. The string form of the item does not change, so each other view of the buffer sees the same value. The write needs the address of the item: keep the index of the last item in the loop state.
3. `lindex` in an `access` followed by a number operator: the same write-back through the list pointer that the `access` read.
4. The write is valid only for a canonical text. `7.50`, `0x10`, ` 7`, and `1e3` stay strings.

With step 2 of idea 6, a string that became a list can get its items changed in the same way, because the text of the list stays in `ListObj.text`.

### Expected gain

Estimate: the second and each later read of an item needs no parse. `csv.tcl` reads each field one time, so it gains only from step 1 (under 5 %). A script that reads a table of numbers in many passes gains the 13 %.

### Risk and rules

- Low to medium. The write to a shared buffer is safe only because the string form is equal. The heap has one thread for each interpreter.
- **Tcl 8.6 semantics:** check `-0`, `+5`, `05`, `1.0`, `1.`, `.5`, `1e5`, `inf`, `nan`, and an integer above 64 bits: each one keeps its text. `string is` and `string length` of the item give the results of today.
- **Same output and count:** `shimmer` uses no compute unit. Keep it so.

## 10. Ownership of inner lists and dicts

### Evidence

| Case | ztcl | tclsh | Ratio |
|---|---|---|---|
| `m_lsetnest`: `lset m $i $j $v`, 50 rows of 50 | 211.1 ms | 50.3 ms | 4.2 |
| `m_dictnest`: `dict set d $a $b $v`, 100 keys of 10 | 794.7 ms | 65.1 ms | 12.2 |
| `d_lappend`: `dict lappend d $k $i`, 100 keys | 271.6 ms | 23.8 ms | 11.4 |
| `dlapp` of `structs.tcl`: `dict lappend r tags old` | 145.0 ms | 268.4 ms | 0.5 |

In instructions, `m_lsetnest` uses 665 M against 327 M, and `m_dictnest` 682 M against 456 M. Their cycle counts are 742 M against 168 M and 914 M against 258 M, so the cost is in the copies.

### Cause

A cell owns only the outer buffer. `lsetRec` (`src/more.zig`) and `dict.setIn` copy each level below it, because an inner `ListObj` can have another holder. ztcl has no reference count, so it cannot ask if a buffer has one holder.

### Design

A stamp shows that an inner buffer was made for the owned buffer that holds it, and that no read took it out since.

1. Add `own_stamp: u64 = 0` to `ListObj`. Add `own_clock: u64 = 1` to `Interp`.
2. When a write copies an inner list or dict to put it in an owned buffer (`lsetRec`, `dict.setIn`, `dict lappend`, `dict append`), set `inner.own_stamp = it.own_clock`.
3. A write on a path through an owned cell: at each level, when the child is a list value and `child.obj.own_stamp == it.own_clock`, write in place in the child. In the other case copy the child, stamp the copy, and store it in the parent in place.
4. Each event that can give an inner buffer a second holder adds 1 to `it.own_clock`. That makes each stamp of the interpreter invalid in one step. The events: an owned cell ends its ownership (`loadSlow`, `Var.settle`, `readRef`), an `access` on an owned cell returns a value with the tag `.list` (`lindex $m 3` returns a row), and a `dict get` of idea 3 returns a list. A result that is an integer, a double, or a string adds no holder.
5. After the clock changes, the next write to each inner buffer copies it one time and stamps it again. So a loop that only writes pays one copy for each inner buffer, and a loop that reads a row between two writes pays one copy for each write, as today.

The clock is one counter for the interpreter. A finer form keeps a clock in each owned outer `ListObj`. Start with the one counter and measure.

### Expected gain

Estimate: `m_lsetnest` and `m_dictnest` reach the cost of a write with one level, about 2 times faster than `tclsh` in place of 4 to 12 times slower. `d_lappend` the same.

### Risk and rules

- High. A missed event lets a script see a value change after a copy. The test of `tests/jit/owned_lists.tcl` must grow with each read form of each level.
- **Tcl 8.6 semantics:** the fuzzer of ownership must make copies of inner values through each read command and then write the outer variable. Add a stress mode that adds 1 to the clock at each instruction: the output must be equal with and without it. That proves that a stale stamp only costs a copy.
- **Same output and count:** the copy and the in-place write must use the same compute units.
- Order: after ideas 3 and 4, because they define the read forms that keep the ownership.

## 11. A faster mark, and a study of sticky mark bits

### Evidence

The share of the collector (`heap.markHit`, `heap.drain`, and the sweep) in the cycles: `pq.tcl` 10 %, `tmpl.tcl` 10 %, `csv.tcl` 16 %, `structs.tcl` 25 %, and 30 % in a script that builds 150,000 records and reads them (the `mk` and `filt` procs of `structs.tcl`, 150 MB live). `Heap.alloc` has 3 % to 20 %.

### Cause

- `scan` (`src/heap.zig`) reads each word of each live block and calls `markHit` for each word inside the bounds of the heap. `markHit` finds the span, tests two bitmaps, and pushes the block. Each of these steps can miss the cache, and the code issues no prefetch.
- A buffer of values has three words for each value. Only the first word of a `.str` or `.list` value is an address. The scan reads the three words.
- Each collection marks each live block. A script that builds a large structure pays the mark of the whole structure at each collection. The threshold is 2 or 4 times the live bytes, so the total mark work is a constant times the allocation, with a large constant in the growth phase.
- An allocation goes through the `Allocator` interface: an indirect call, the class of the size, and the bitmap.

### Design

Step 1, low risk:

1. A prefetch queue in `drain`: keep the last 8 candidate addresses in a ring. When `scan` finds a candidate, issue `@prefetch` for its span lookup entry and push it in the ring. Process the entry that leaves the ring. The mark result does not change.
2. A direct allocation function for the hot sizes: `Heap.allocSmall(comptime class)` with no interface call, for the cells, the list of one block (`value.allocList`), and the string of an integer. The size class is a compile-time constant.
3. Measure a lower first threshold. `min_threshold` is 16 MiB, above the 8 MB cache of the test machine. With idea 1 in place, try 4 MiB for a heap whose live data is under 1 MiB. The trigger must stay a function of the allocation history alone.

Step 2, a study before any code: sticky mark bits. A collection keeps the mark bits of the blocks that lived through the last one, and marks only from the roots and from old blocks that changed. ztcl writes to an old block in few places: a cell, a frame, an array map, an in-place append, an in-place `lset` or `dict set`, the caches of the interpreter, and the inline `lappend` of the JIT. The study must list each such write, define a remembered set (a bit for each span), and define a check mode that runs a full mark after each partial mark and compares the two. A missed write is a use after free, so this step needs the fuzzer and the check mode before it merges. WebAssembly has precise roots, and the study must cover it.

### Expected gain

Estimate for step 1: the mark gets 20 % to 40 % faster, so a script with 20 % in the collector gains 4 % to 8 %. Step 2 can remove most of the mark of a growing structure. I did not measure a prototype of either step.

### Risk and rules

- Step 1 is low: the set of marked blocks does not change. Step 2 is high.
- **Deterministic units:** the trigger of a collection reads no clock and no address (the review list, "The collector"). A change of `min_threshold` changes the point where a script with a small memory limit collects. It does not change the output of a script that stays under its limit.
- **Same output and count:** `memUsed` must stay equal with the JIT on and off. The JIT does not allocate in the heap, so each step keeps this.
- Order: after idea 1, because idea 1 changes the cost of a collection with little live data.

## 12. A value of 16 bytes

### Evidence

A `Value` has 24 bytes: 16 bytes of payload (a slice, or a list pointer and a length) and a tag. A `Var` has 40 bytes. `memmove` and `memcpy` have 5 % to 10 % of the cycles of `pq.tcl`, `wordfreq.tcl`, and `tmpl.tcl`. The 150,000 records of `structs.tcl` use 145 MB, about 960 bytes for each record of four keys and one list of three items. `docs/dev/jit.md` notes that a copy of a value in machine code is three moves.

### Design

1. The layout: word 0 is the payload (the integer, the bits of the double, the address of the string bytes, or the address of the `ListObj`). Word 1 is the length in the low 56 bits and the tag in the high 8 bits. Word 0 stays a plain address, so the conservative scan of the collector finds it.
2. A string or a list view then has a length under 2^56. That is no limit in practice.
3. `Value` becomes an `extern struct` with access functions. Each `switch (v)` on the union (several hundred sites) must change to a switch on `v.tag()`.
4. `jit/layout.zig` finds the tag with a probe today. With a fixed layout, the probe becomes a compile-time check. Each tag check of each template changes from a byte compare at offset 16 to a shift and a compare of word 1, on x86-64 and arm64, in both tiers.

### Expected gain

Estimate: each list, dict, and stack uses 33 % less memory, and a copy of a value is one 16-byte move. I did not measure a prototype. A prototype of the layout with the interpreter alone (`-Djit=false`) gives the real number at a low cost, and that measure goes first.

### Risk and rules

- High, and the change is large. It touches each template of four code generators while the ports are active. Do it last, after the arm64 Linux and Windows JIT work merges.
- **Review list:** "Guards" needs each inline path to check the tag with the mask of the layout. Each template gets a new golden test.
- **Tcl 8.6 semantics:** no change of semantics.

## Measures with no finding

These cases are faster than `tclsh` 8.6.16 in instructions, so they have no idea (the ratio is ztcl divided by `tclsh`): `expr` with math functions (0.18), `lreplace` (0.18), `catch` of an error (0.19), `split` (0.19), `concat` (0.27), `join` (0.28), a proc with `args` (0.30), string building with `set s "$s$i,"` (0.33), `string reverse` and `string trimleft` (0.36), a complex integer `expr` (0.37), `{*}` (0.37), `while` (0.39), a proc with a default (0.40), `lrange` (0.40), `global` (0.41), `scan` (0.41), `linsert` (0.43), `string compare` and `string equal -nocase` (0.43), `try` (0.44), an array with string keys (0.45), `upvar` (0.50), a namespace variable (0.51), a coroutine (0.53), `binary format` and `binary scan` (0.54), `format` (0.54), and string commands on a short string (0.64). A method call of TclOO uses 1,230 instructions against 2,500 to 2,900.

Not measured: ztk and its renderer, the threads, the WebAssembly build, arm64, and Tcl 9. The real-world suite of issue #242 did not exist at this commit, so `bench/ideas/` has six small programs of the same kinds.

## What is new for a Tcl

- Ideas 3, 4, and 10 give in-place updates with no reference count. Ownership is a state of the variable, and a stamp extends it to inner values.
- Idea 6 step 2 gives a value its two forms with no object header: the text is a field of the list buffer.
- Idea 1 keeps the memory count exact while the process keeps the pages. The count stays a pure function of the script.
- Idea 7 keeps the exact count of ticks in a DFA that lives across calls, so a cached state and a new state give the same compute units.
