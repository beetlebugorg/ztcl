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
| 2 | `eval` of a list parses text on each call | 89.0 ms | 29.3 ms | 3.0 | Small | Open |
| 3 | `lmap` has no bytecode | 67.5 ms | 39.1 ms | 1.7 | Small | Open |
| 4 | `lsearch -exact` orders each item | 14.7 ms | 9.0 ms | 1.6 | Small | Done: 6.6 ms |
| 5 | `string map` tries each key at each byte | 26.6 ms | 16.9 ms | 1.6 | Small | Open |
| 6 | The regex search has no literal scan | 6.05 ms | 1.00 ms | 6.0 | Medium | Open |
| 7 | Array elements go through the name of the variable | 104.8 ms | 70.9 ms | 1.5 | Medium | Open |
| 8 | A proc call uses about 250 instructions in `callProcFast` | 14.8 ms | 70.5 ms | 0.2 | Large | Open |
| 9 | `append` in JIT code goes through two helpers | 243.1 M instructions | 812.4 M | 0.3 | Medium | Open |
| 10 | `read` of a whole file | 73.5 ms | 49.9 ms | 1.5 | Not known | Open |

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

## 3. `lmap` has no bytecode

```tcl
proc lmapl {} {set l {}; for {set i 0} {$i<100000} {incr i} {lappend l $i}; set n 0; for {set k 0} {$k<5} {incr k} {incr n [llength [lmap x $l {expr {$x*2}}]]}; return $n}
```

- Measure: 67.5 ms in ztcl, 53.0 ms with the JIT, 39.1 ms in `tclsh`.
- Profile: 362.7 M instructions. `findVar` has 16.5%, `cmdForeach` 9.8%, `setVar` 7.7%, `evalScript` 5.8%.
- Cause: `foreach` is in `inline_names` (`src/vm.zig:172`) and compiles at `src/vm.zig:699`. `lmap` is not in the list, so it runs `cmdForeach` (`src/cmds.zig:330`), and that function sets the loop variable by name and calls the body as a script on each pass.
- Change: compile `lmap` with the `foreach` code and one result list.
- Expected gain: `foreach.tcl` runs in 16.2 ms against 33.2 ms for `tclsh` (`docs/performance.md`). `lmap` can reach a similar ratio. Tier 2 of the JIT can then compile the loop.

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

## 7. Array elements go through the name of the variable

```tcl
proc arr {} {for {set i 0} {$i<200000} {incr i} {set a($i) $i}; set s 0; for {set i 0} {$i<200000} {incr i} {incr s $a($i)}; return $s}
```

- Measure: 104.8 ms in ztcl, 92.0 ms with the JIT, 70.9 ms in `tclsh`.
- Profile: 591.5 M instructions. `vm.exec` has 17.0%, `heap.Heap.alloc` 8.5%, `heap.drain` 6.7%, `findVar` 6.6%, `heap.markHit` 5.4%.
- Cause: `getElem` (`src/interp.zig:2725`) calls `findVar` with the name of the array on each read, and the map of the array has string keys. A local scalar uses a slot, and an array does not. I did not find which allocation makes the 8.5%.
- Change: add bytecode for the read and the write of `name(index)` that finds the array through the slot of the local variable. Hash an integer index without a string copy when the key is already in the map.
- Expected gain: `findVar` goes away from the loop (6.6%). The gain from the allocations is not known before the source of them is found.

## 8. A proc call uses about 250 instructions in `callProcFast`

- Measure: `perf stat -e instructions:u zig-out/bin/ztcl --jit --jit-tier2 bench/fib.tcl` gives 106.0 M instructions. The interpreter gives 151.0 M. `fib 25` makes 242,785 calls.
- Profile with `--jit`: `callProcFast` and the code inlined into it have 61.0 M instructions (57.5%). That is 251 instructions for each call. The JIT code of the body has 28.6 M (27.0%).
- `--jit-stats` prints `tier2=0` for `fib.tcl`. Tier 2 compiles loops only (`src/jit/tier2.zig:7`), so a proc with no loop stays in tier 1.
- Cause: each call from JIT code goes to a helper and then to `callProcFast` (`src/interp.zig:2329`), and this function builds the frame, checks the limits, and binds the arguments in the general way.
- Change: a direct call from JIT code to the JIT code of a proc with a fixed argument count, no default, and no `args`. Check the epoch, push a frame from a pool, and jump. Keep the depth, nest, native stack, and step checks.
- Expected gain: the upper limit is the 57.5%. This is the largest change of the list, and rule 10 of `AGENTS.md` (same steps and same memory count) applies to each part.

## 9. `append` in JIT code goes through two helpers

- Measure: `perf stat` gives 243.1 M instructions for `bench/strbuild.tcl` with `--jit --jit-tier2` (`docs/performance.md`). Tier 2 compiled the loop (`tier2=1`), and the count dropped only from 252.5 M to 243.1 M.
- Profile: `Interp.appendStr` has 27.1%, one helper wrapper has 22.6% and 10.6% more from `value.zig`, and `memcpy` has 12.5%. The loop does 500,000 appends, so `appendStr` uses about 132 instructions for each append.
- Cause: the profile shows two helper wrappers in the loop, and `appendStr` copies the new part. I did not read which instruction each wrapper serves. The probable sequence is one helper that makes the string for `"x$i,"` and one helper that appends it.
- Change: one helper for "append these parts to this variable" that writes the digits of the integer and the literal parts into the free capacity of the target. A later step is an inline fast path in JIT code for a target with free capacity.
- Expected gain: the temporary string and one of the two copies go away. I did not measure a prototype.

## 10. `read` of a whole file

```tcl
proc ra {f} {set c [open $f r]; set d [read $c]; close $c; llength [split $d \n]}
```

- Measure, a file of 300,000 lines and 11.6 MB: 73.5 ms in ztcl, 49.9 ms in `tclsh`. Command: `zig-out/bin/ztcl --allow clock,file,channels --root <folder> io.tcl`.
- In the same script, 300,000 `puts` to the file ran in 73.5 ms against 97.2 ms, and 300,000 `gets` ran in 82.9 ms against 136.1 ms. So the line paths are faster than `tclsh`.
- Cause: not checked. `split` and `join` on a string of 2,000 items are faster than `tclsh` (40.6 ms against 46.4 ms), so the first place to look is `read` in `src/chan.zig`: the growth of the buffer and the encoding pass.
- Change: profile `read` alone first.

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
