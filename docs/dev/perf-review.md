# Performance review

This page lists the places where ztcl can get faster, with a measure for each one. It is a review. It changes no code. The dict growth path and `base64` have their own work and are not in this review.

## Method

- Date: 2026-11-25. Commit: `1ea81b6`. Machine: Intel Core i7-6700K, x86-64 Linux. Zig 0.16.0. `tclsh` is 8.6.16.
- Build: `zig build -Doptimize=ReleaseFast`.
- Times are wall milliseconds of one proc, from `clock microseconds` around one call, one run. Other jobs shared the machine, so the times are rough. The command is `zig-out/bin/ztcl --allow clock micro.tcl`, with `--jit --jit-tier2` for the JIT column, and `tclsh micro.tcl`.
- `micro.tcl` has the procs that the findings show, and this timer:

```tcl
proc t {name body} {
    set t0 [clock microseconds]
    uplevel #0 $body
    puts [format "%-14s %7.1f ms" $name [expr {([clock microseconds]-$t0)/1000.0}]]
}
```

- Instruction counts are from `valgrind --tool=callgrind zig-out/bin/ztcl one.tcl` and `callgrind_annotate`, where `one.tcl` has one proc and one call. `perf record` did not open an event on this machine. `perf stat -e instructions:u` works.

## Summary

The rank is the expected gain divided by the effort. A ratio above 1 means that ztcl is slower than `tclsh`.

| Rank | Finding | ztcl | tclsh 8.6.16 | Ratio | Effort | Status |
|---|---|---|---|---|---|---|
| 1 | `string index` and `string length` read the whole string | 1,027.4 ms | 28.1 ms | 36.6 | Small to medium | Done: 17.7 ms |
| 2 | `eval` of a list parses text on each call | 89.0 ms | 29.3 ms | 3.0 | Small | Done: 17.9 ms |
| 3 | `lmap` has no bytecode | 67.5 ms | 39.1 ms | 1.7 | Small | Done: 22.4 ms |
| 4 | `lsearch -exact` orders each item | 14.7 ms | 9.0 ms | 1.6 | Small | Done: 6.6 ms |
| 5 | `string map` tries each key at each byte | 26.6 ms | 16.9 ms | 1.6 | Small | Done: 15.6 ms |
| 6 | The regex search has no literal scan | 6.05 ms | 1.00 ms | 6.0 | Medium | Done: 0.3 ms |
| 7 | Array elements go through the name of the variable | 104.8 ms | 70.9 ms | 1.5 | Medium | Done: 55.4 ms |
| 8 | A proc call uses about 250 instructions in `callProcFast` | 14.8 ms | 70.5 ms | 0.2 | Large | Done on x86-64: 92.2 M instructions for `fib.tcl` |
| 9 | `append` in JIT code goes through two helpers | 243.1 M instructions | 812.4 M | 0.3 | Medium | Done: 200.4 M |
| 10 | `read` of a whole file | 73.5 ms | 49.9 ms | 1.5 | Not known | Done: 11.0 ms |

## 1. `string index` and `string length` read the whole string

```tcl
proc strindex {} {set s [string repeat abcdefghij 1000]; set n 0; for {set k 0} {$k<30} {incr k} {for {set i 0} {$i<10000} {incr i} {if {[string index $s $i] eq "c"} {incr n}}}; return $n}
```

- Measure: 1,027.4 ms in ztcl, 1,125.3 ms with the JIT, 28.1 ms in `tclsh`.
- Second measure: 1,000 calls of `string length` on a string of 360,000 bytes ran in 125.6 ms in ztcl and in 0.18 ms in `tclsh`. The same loop on 90,000 bytes ran in 30.7 ms, so the time grows with the length.
- Cause: `charCount` (`src/cmds.zig:1501`) reads each byte. `opStringLength` (`src/vm.zig:1592`) and `string index` (`src/cmds.zig:1554`) call it on each use. `string index` then calls `byteOf` two times.
- Change, step 1: count with 32-byte vectors in `charCount`. This keeps the cost linear and makes the constant smaller.
- Change, step 2: keep the character count with the string, or keep an "all ASCII" bit. With the bit set, `string index` is one bounds check and one slice. `docs/dev/values.md` is the place to decide where the count goes.
- Expected gain: step 2 makes `strindex` independent of the length of the string. I did not measure a prototype.
- Done: `charCountOf` (`src/cmds.zig`) keeps the count of a string of 256 bytes or more in a cache of four entries in the heap. An entry has the address and the length of the string. The bytes of a live heap block do not change, so a sweep or a reset of the heap clears the cache. A string outside the heap gets no entry. After the change, `strindex` runs in 17.7 ms (13.2 ms with the JIT) against 27.5 ms for `tclsh`. Before the change it ran in 78.0 ms on the same machine. The 1,000 calls of `string length` on 360,000 bytes run in 0.2 ms against 0.4 ms for `tclsh`.

## 2. `eval` of a list parses text on each call

```tcl
proc evals {} {set n 0; for {set i 0} {$i<100000} {incr i} {eval [list incr n $i]}; return $n}
```

- Measure: 89.0 ms in ztcl, 78.0 ms with the JIT, 29.3 ms in `tclsh`.
- Profile: 602.5 M instructions. `heap.Heap.alloc` has 14.4%, `Parser.parseScript` 8.3%, `Parser.parseParts` 5.7%, `scriptOfText` 5.7%.
- Cause: `cmdEval` (`src/cmds.zig:881`) makes the text of the list and compiles it. The text changes on each pass, so the cache of `scriptOfText` (`src/interp.zig:1755`) has no hit, and each pass adds one entry.
- Change: when the one argument is a list value, call the command with the items of the list as its words. Do not make the text, and do not compile.
- Expected gain: the parse and compile part goes away. `tclsh` has this path, and its time is 29.3 ms. The same change helps `uplevel`, `after`, and each callback that an embedder builds with `list`, when they use the same function. I did not check those paths.
- Done: `cmdEval` gives a list value to `evalWords` (`src/interp.zig`). It copies the items to the value stack and calls the command, with no text and no compile. The error trace has the text of the list, as before. `evals` runs in 17.9 ms (17.2 ms with the JIT) against 28.7 ms for `tclsh`. Before the change it ran in 62.9 ms on the same machine.

## 3. `lmap` has no bytecode

```tcl
proc lmapl {} {set l {}; for {set i 0} {$i<100000} {incr i} {lappend l $i}; set n 0; for {set k 0} {$k<5} {incr k} {incr n [llength [lmap x $l {expr {$x*2}}]]}; return $n}
```

- Measure: 67.5 ms in ztcl, 53.0 ms with the JIT, 39.1 ms in `tclsh`.
- Profile: 362.7 M instructions. `findVar` has 16.5%, `cmdForeach` 9.8%, `setVar` 7.7%, `evalScript` 5.8%.
- Cause: `foreach` is in `inline_names` (`src/vm.zig:172`) and compiles at `src/vm.zig:699`. `lmap` is not in the list, so it runs `cmdForeach` (`src/cmds.zig:330`), and that function sets the loop variable by name and calls the body as a script on each pass.
- Change: compile `lmap` with the `foreach` code and one result list.
- Expected gain: `foreach.tcl` runs in 16.2 ms against 33.2 ms for `tclsh` (`docs/performance.md`). `lmap` can reach a similar ratio. Tier 2 of the JIT can then compile the loop.
- Done: `compileForeach` compiles `lmap` with the `foreach` loop. The result list is on the stack below the loop state, and the new instruction `lmap_add` appends the result of each pass that ends with no `continue`. The JIT verifier checks that the loop state is under the top of the stack. Tier 2 keeps no stack place below the head of a loop, so a loop with `lmap_add` stays in tier 1. `lmapl` runs in 22.4 ms (23.4 ms with the JIT) against 38.0 ms for `tclsh`. Before the change it ran in 47.5 ms on the same machine.

## 4. `lsearch -exact` orders each item

```tcl
proc lsrch {} {set l {}; for {set i 0} {$i<2000} {incr i} {lappend l k$i}; set n 0; for {set i 0} {$i<2000} {incr i} {incr n [lsearch -exact $l k$i]}; return $n}
```

- Measure: 14.7 ms in ztcl, 12.7 ms with the JIT, 9.0 ms in `tclsh`.
- Profile: 158.3 M instructions, and 95% of them are in `cmdLsearch` and the code inlined into it.
- Cause: the exact match uses `std.mem.order` (`src/cmds.zig:1253`). It finds the order of the two strings byte by byte, and the search needs only "equal".
- Change: for `-exact` with no `-sorted` and no `-bisect`, compare the lengths first and then call `std.mem.eql`. Keep `order` for the sorted modes.
- Expected gain: most items differ in length or in the first bytes, so the loop becomes one length compare for each item. I did not measure a prototype.
- Done: the first exact match of a string, with no `-index`, `-all`, `-not`, or `-nocase`, goes through its own loop that compares the lengths and then the bytes. A swap of `order` for `eql` in the general loop gave no gain, because the loop itself used most of the instructions. `lsrch` runs in 6.6 ms against 8.4 ms for `tclsh`. Before the change it ran in 12.6 ms on the same machine.

## 5. `string map` tries each key at each byte

```tcl
proc strmap {} {set s [string repeat "hello world foo bar " 5000]; set n 0; for {set i 0} {$i<30} {incr i} {incr n [string length [string map {foo quux o 0} $s]]}; return $n}
```

- Measure: 26.6 ms in ztcl, 16.9 ms in `tclsh`.
- Profile: 384.1 M instructions. `cmdString` has 41.3% and `mem.eqlBytes` has 38.3%.
- Cause: the loop at `src/cmds.zig:1654` calls the meter and `eql` for each key at each byte of the string, and appends one byte at a time when no key matches.
- Change: build a table of 256 bits from the first byte of each key. Skip a byte that is in no key with one table read. Copy each run of such bytes with one `appendSlice`. With `-nocase`, put both cases in the table.
- Expected gain: the 38.3% in `eqlBytes` drops to the bytes that start a key. The meter must charge the same units of work as today.
- Done: a table of the first bytes of the keys finds each run of bytes that starts no key, and the run goes to the output with one `appendSlice`. The meter gets the units of the compares that the run skips, so the step count does not change. `strmap` runs in 15.6 ms against 16.9 ms for `tclsh`. Before the change it ran in 32.4 ms on the same machine.

## 6. The regex search has no literal scan

```tcl
set s [string repeat "the quick brown fox 123 jumps " 12000]
regexp -all {zzz} $s
regsub -all {\d+} $s X
```

- Measure, pattern with no match on 360,000 bytes: 6.05 ms in ztcl, 1.00 ms in `tclsh`.
- Measure, `regsub -all` with 12,000 matches: 10.98 ms in ztcl, 6.17 ms in `tclsh`.
- Profile of ten `regsub -all {\d+}` calls on 90,000 bytes: 250.9 M instructions. `Matcher.search` has 42.1%, `Matcher.addThread` 25.4%, the append of a thread 11.7%, `Set.rawHas` 8.9%.
- Cause: `search` (`src/regex.zig:1522`) starts the thread simulation (`src/regex.zig:1292`) at each position. A search for `first_set`, `first_byte`, or `prefix` in `src/regex.zig` finds no such field, so no pattern skips ahead with a byte scan.
- Change, step 1: at compile time, find the set of bytes that can start a match, and the literal prefix when the pattern has one. In `simulate`, when the thread list is empty, go to the next candidate with `std.mem.indexOfScalar`, `indexOfAny`, or `indexOf`.
- Change, step 2: a lazy DFA for patterns with no back reference and no capture need.
- Expected gain: step 1 makes the no-match case a `memchr` scan. `tclsh` shows 1.00 ms for it. The step counter of the matcher must give the same count as today, or the limits of a script change.
- Done: step 1. When the closure of instruction 0 has no assert, no lookahead, and no match, `compile` keeps a table of the characters that a first thread accepts (`Start` in `src/regex.zig`). With no live thread, `simulate` goes to the next such character with a scan and adds the ticks of the skipped positions, so the step count does not change. The proc with the pattern `zzz` runs in 0.5 ms against 2.0 ms for `tclsh`. The proc with `regsub -all` runs in 2.5 ms against 6.4 ms. Both procs include the `string repeat`. Before the change they ran in 5.6 ms and 8.2 ms on the same machine.
- Done: step 2. Before the first match, a program with a `Start` and with no assert and no lookahead runs as a lazy DFA (`Dfa` in `src/regex.zig`). A state is the list of thread instructions at a position, with the rank of the start of each thread. The ticks of one step depend only on the instructions and the character, so each transition keeps its ticks, and the step count does not change. A transition also keeps the source of the start of each rank. A step that reaches a match has a mark, and the simulation goes on from that step. One call of `regexp` or `regsub` makes at most 64 states. The script of 20 patterns on an ASCII text and on a text with non-ASCII characters gives the output of `tclsh` and the step count of main (410,308), and a step limit sweep gives the same output and steps as main. Best of 5, on the text of 360,000 bytes:

| Proc | main | DFA | `tclsh` |
|---|---|---|---|
| `regexp -all {zzz}` | 0.30 ms | 0.30 ms | 0.95 ms |
| `regsub -all {\d+} $s X` | 2.49 ms | 2.51 ms | 4.97 ms |
| `regexp -all {[a-z]+ps}` | 16.00 ms | 2.77 ms | 7.67 ms |
| `regexp -all {(fox\|dog) [0-9]+}` | 5.04 ms | 3.54 ms | 10.69 ms |
| `regexp -all {o[^ ]*s}` | 3.44 ms | 0.69 ms | 0.95 ms |

- The instruction count of one `regsub -all {[a-z]+ps}` call goes from 200.3 M to 42.7 M. For `regsub -all {\d+}` it goes from 25.8 M to 27.1 M: each of the 12,000 matches starts a new search, and the DFA of a search ends at the first digit.

## 7. Array elements go through the name of the variable

```tcl
proc arr {} {for {set i 0} {$i<200000} {incr i} {set a($i) $i}; set s 0; for {set i 0} {$i<200000} {incr i} {incr s $a($i)}; return $s}
```

- Measure: 104.8 ms in ztcl, 92.0 ms with the JIT, 70.9 ms in `tclsh`.
- Profile: 591.5 M instructions. `vm.exec` has 17.0%, `heap.Heap.alloc` 8.5%, `heap.drain` 6.7%, `findVar` 6.6%, `heap.markHit` 5.4%.
- Cause: `getElem` (`src/interp.zig:2725`) calls `findVar` with the name of the array on each read, and the map of the array has string keys. A local scalar uses a slot, and an array does not. I did not find which allocation makes the 8.5%.
- Change: add bytecode for the read and the write of `name(index)` that finds the array through the slot of the local variable. Hash an integer index without a string copy when the key is already in the map.
- Expected gain: `findVar` goes away from the loop (6.6%). The gain from the allocations is not known before the source of them is found.
- Done: step 1, the read. `readRef` finds a local array through the slot hint of the reference, as a scalar read does, and an index of one part uses the string of that part with no copy. `arr` runs in about 75 ms (64.8 ms with the JIT) against 75.9 ms for `tclsh`. Before the change it ran in about 90 ms (86.5 ms with the JIT) on the same machine. The write of `set a($i)` still made the full name and called `findVar`.
- Done: step 2, the write. `set name(index) value`, with a literal plain name before the "(", compiles to the instruction `store_elem` on the slot of the array. The instruction writes to a plain array or to an unset variable with no full name. A cell with a trace, a link to an element, or a scalar value goes through `setVar` with the full name. The JIT calls the same function as a helper. Best of 5: `arr` runs in 55.4 ms (53.0 ms with the JIT) against 67.1 ms for `tclsh`. Main ran it in 62.4 ms (60.3 ms with the JIT) on the same machine. The instruction count of one `arr` call goes from 472.3 M to 371.4 M, and from 419.2 M to 312.6 M with the JIT.

## 8. A proc call uses about 250 instructions in `callProcFast`

- Measure: `perf stat -e instructions:u zig-out/bin/ztcl --jit --jit-tier2 bench/fib.tcl` gives 106.0 M instructions. The interpreter gives 151.0 M. `fib 25` makes 242,785 calls.
- Profile with `--jit`: `callProcFast` and the code inlined into it have 61.0 M instructions (57.5%). That is 251 instructions for each call. The JIT code of the body has 28.6 M (27.0%).
- `--jit-stats` prints `tier2=0` for `fib.tcl`. Tier 2 compiles loops only (`src/jit/tier2.zig:7`), so a proc with no loop stays in tier 1.
- Cause: each call from JIT code goes to a helper and then to `callProcFast` (`src/interp.zig:2329`), and this function builds the frame, checks the limits, and binds the arguments in the general way.
- Change: a direct call from JIT code to the JIT code of a proc with a fixed argument count, no default, and no `args`. Check the epoch, push a frame from a pool, and jump. Keep the depth, nest, native stack, and step checks.
- Expected gain: the upper limit is the 57.5%. This is the largest change of the list, and rule 10 of `AGENTS.md` (same steps and same memory count) applies to each part.
- Resume: start in `src/jit/tier1_x64.zig` (`invoke`, and the helper `call_cached` of `src/jit/helpers.zig`) and in `callProcFast` (`src/interp.zig`). Keep the order of the checks in `callProcFast`: the depth, the nest, the native stack, and the step. `tools/jit-diff.sh` compares the steps and the memory count, so a frame from a pool must count the same bytes as the frame of `callProcFast`. Do the x64 backend first, then `tier1_a64.zig`.
- Profile of 2026-11-25 (commit `6e43354`, callgrind, `--jit --jit-tier2 bench/fib.tcl`, 106.0 M instructions for 242,785 calls): the code of `src/interp.zig` inlined into `callProcFast` has 163 instructions for each call, the JIT code of the body 118, `src/jit.zig` (`enter`) 56, `src/vm.zig` (`runInline`, `runReady`, `opInvokeCached`) 32, and the wrapper of `call_cached` about 64. No one line has more than 21 instructions for each call. The largest lines are the start values of the cells in `runProcFast` (21), the call of `it.call` in `opInvokeCached` (15), and the entry of `callProcFast` (11). So a gain needs a path that skips the layers: `call_cached`, `Interp.call`, `runProcFast`, `runReady`, and the build of `EnterCtx` in `jit.enter`.
- Design: the template of `invoke` calls a new helper `call_direct` (`src/jit/call.zig`) when the site cache is valid, in place of `call_cached`. The helper serves a proc with ready machine code of the current generation, one word for each parameter, and no `args`. Each other command goes to `vm.opInvokeCached`, as before. The helper does the work of `opInvokeCached`, `callProcFast`, `runReady`, and `jit.enter` in one function and in their order: the step check, the frame and its cells, the namespace, the native stack check, the nest check, the value stack, and the call of the body at address 0. On the status "done", it gives back the value stack, the nest, the namespace, and the frame, and copies the result one time to the stack slot of the command. An error, or an exit to the interpreter in the body, goes to `vm.runRest` and then to the end of `callProcFast`: `procEnd`, the namespace, the frame, and a pending tail call.
- Semantics: the helper calls the same functions as the general path for each part that can fail or that a script can see: `vm.step`, `takeFrame`, `checkNative`, `stackAlloc`, `runRest`, `procEnd`, and `runTail`. So the step count, the error texts, `errorInfo`, `-errorline`, the frames of `info level` and `uplevel`, the depth limit, and the memory count stay the same. A redefined proc, a `rename`, a change of the namespace, and a trace on the command change the epoch or the site, so the inline checks of the site fail and the call goes to the helper of `invoke`. A body that leaves its machine code in the middle continues in `exec` in the frame of the call, as with `jit.enter`.
- Rejected forms, from callgrind on `fib.tcl` with `--jit`: a pair of helpers `call_enter` and `call_leave`, with the context of the callee on the native stack of the caller and the call of the body from the machine code, gave 109.2 M instructions. One helper that returned the result through an error union for each part gave 103.1 M. Main gives 106.0 M. The cost of these forms is in the copies of the result and in the saved registers of each native frame, so the chosen form has one frame and one copy.
- arm64 (for the port on macOS): `src/jit/call.zig` has no code for one target. The arm64 change is the hit path of `invoke` in `tier1_a64.zig` and the call of `call_cached` in `tier2_a64.zig`: each one calls `.call_direct` in place of `.call_cached`, with the same three arguments. `call.zig` runs `mem.checkClosed` before the call of the body, as `jit.enter` does, for the write window of Apple silicon. The gates are the same as on x86-64, plus `src/jit/a64_golden.zig` and the macOS JIT job.
- Done on x86-64 (2026-11-25): the design above, in `src/jit/call.zig`, for the hit path of `invoke` in tier 1 and tier 2. Callgrind counts with `--jit`: `fib.tcl` goes from 106.0 M to 92.2 M instructions (tclsh 600.9 M). 300,000 calls of a proc with two arguments go from 150.0 M to 132.3 M (tclsh 817.8 M). `bf_oo.tcl` with a short program goes from 2,018.8 M to 2,035.0 M (tclsh 5,445.9 M), because its method calls go through `callMethod`. The interpreter counts went up by 0.5 % or less.
- Done on arm64 (2026-11-26): the hit path of `invoke` in `tier1_a64.zig` and in `tier2_a64.zig` calls `.call_direct`. On an Apple M1 with macOS 27.0, `tools/jit-diff.sh` shows no difference in its four modes (none, `-t`, `--stress`, `--stress -t`), `jit-fuzz --verify --tier2` passes, and `proc.test` and `proc-old.test` give the same counts with and without `-j`.
- Build note: two clones that share one `ZIG_LOCAL_CACHE_DIR` can install the binary of the other clone. Give a baseline clone its own cache folder.

## 9. `append` in JIT code goes through two helpers

- Measure: `perf stat` gives 243.1 M instructions for `bench/strbuild.tcl` with `--jit --jit-tier2` (`docs/performance.md`). Tier 2 compiled the loop (`tier2=1`), and the count dropped only from 252.5 M to 243.1 M.
- Profile: `Interp.appendStr` has 27.1%, one helper wrapper has 22.6% and 10.6% more from `value.zig`, and `memcpy` has 12.5%. The loop does 500,000 appends, so `appendStr` uses about 132 instructions for each append.
- Cause: the profile shows two helper wrappers in the loop, and `appendStr` copies the new part. I did not read which instruction each wrapper serves. The probable sequence is one helper that makes the string for `"x$i,"` and one helper that appends it.
- Change: one helper for "append these parts to this variable" that writes the digits of the integer and the literal parts into the free capacity of the target. A later step is an inline fast path in JIT code for a target with free capacity.
- Expected gain: the temporary string and one of the two copies go away. I did not measure a prototype.
- Done: a callgrind profile with `--jit --jit-tier2` shows one helper in the loop, the `append` instruction. It writes the digits of the integer to a buffer on the native stack and makes no temporary string, so the two helpers of the cause above do not exist. The cost was in `appendStr`, with one call of `memcpy` for each part of one to six bytes. A part of 8 bytes or less now copies in a loop. `bench/strbuild.tcl` uses 200.4 M instructions with the JIT, against 227.3 M before. The interpreter uses 286.7 M against 313.6 M. The wall time with the JIT went from 20 ms to 19 ms, against 67 ms for `tclsh`. An inline fast path in JIT code is not done, because the helper is already one call for each append.

## 10. `read` of a whole file

```tcl
proc ra {f} {set c [open $f r]; set d [read $c]; close $c; llength [split $d \n]}
```

- Measure, a file of 300,000 lines and 11.6 MB: 73.5 ms in ztcl, 49.9 ms in `tclsh`. Command: `zig-out/bin/ztcl --allow clock,file,channels --root <folder> io.tcl`.
- In the same script, 300,000 `puts` to the file ran in 73.5 ms against 97.2 ms, and 300,000 `gets` ran in 82.9 ms against 136.1 ms. So the line paths are faster than `tclsh`.
- Cause: not checked. `split` and `join` on a string of 2,000 items are faster than `tclsh` (40.6 ms against 46.4 ms), so the first place to look is `read` in `src/chan.zig`: the growth of the buffer and the encoding pass.
- Change: profile `read` alone first.
- Done: a profile showed 97% of the instructions of `read` in `decode` (`src/chan.zig`), and it appended each byte with a call. It now reserves the length of the input and copies each run of bytes up to the next CR, or in binary mode up to the next CR or high byte. A `read` of the 11.6 MB file runs in 11.0 ms against 21.7 ms for `tclsh`, and `read` with `split` in 25.2 ms against 49.5 ms. Before the change `read` ran in 47.0 ms on the same machine.

## Measures with no finding

These procs of `micro.tcl` were faster than `tclsh` or equal, so they have no finding: proc calls with three arguments (23.0 ms against 70.5 ms), `catch` of an error (49.8 against 272.0), `switch` (12.7 against 30.7), `lset` (14.8 against 32.2), `format` (95.9 against 145.8), `scan` (37.5 against 88.9), `regexp` with captures on short strings (133.2 against 252.7), `upvar` (35.9 against 70.9), `lsort -integer` of 200,000 items (77.2 against 73.4), and `lsort` of 100,000 strings (53.5 against 53.5).

## Proposed issue titles

1. Keep the character count of a string so `string index` and `string length` do not scan
2. Count characters with vectors in `charCount`
3. Call the command directly when `eval` gets a list
4. Compile `lmap` with the `foreach` bytecode
5. Use an equality compare in `lsearch -exact`
6. Skip bytes that start no key in `string map`
7. Add a first-byte and literal-prefix scan to the regex search
8. Add bytecode for array element reads and writes
9. Call JIT code of a proc directly from JIT code
10. Append integer and literal parts with one helper
11. Profile `read` of a whole file
