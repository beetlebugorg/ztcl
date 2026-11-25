# Faster values: arenas, shapes, and lazy JSON

`zt::json parse` makes Tcl values at about one fifth of the speed of simdjson DOM. Stage 1 (the structural index) is close to simdjson. This plan measures where stage 2 spends its time and selects the changes to the value representation and to the build of the values. [The tasks](values-tasks/README.md) have the order of the work.

## The profile

The measures ran on main at a61b78f, with a ReleaseFast runner, on the three files of `tools/bench-stdlib.py`. The instruction counts are exact counts of callgrind for one `zt::json parse -null {} $text`, with the collection of the command only (`--toggle-collect=json.cmd.cmdParse`). The collector counts come from a loop of 20 parses. The memory is the count of `--report --gc off` after one parse, less the count with no parse. Other load on the machine made the times noisy, so the decisions use the instruction counts.

| | twitter.json | canada.json | citm_catalog.json |
|---|---|---|---|
| Size | 631 514 B | 2 251 051 B | 1 727 204 B |
| Instructions of one parse | 8.19 M | 114.1 M | 20.7 M |
| Instructions per JSON byte | 13.0 | 50.7 | 12.0 |
| Stage 1 (`Stream.refill`) | 2.32 M (28 %) | 7.28 M (6 %) | 4.99 M (24 %) |
| Number conversion (`std.fmt.parseFloat`) | below 1 % | 37.9 M (33 %), 101 338 calls | below 1 % |
| Allocation (`Heap.alloc`) | 0.28 M (3 %), 4 226 calls | 7.00 M (6 %), 112 123 calls | 2.15 M (10 %), 34 098 calls |
| Container close (copy and dict build) | 0.77 M (9 %) | 3.31 M (3 %) | 2.30 M (11 %) |
| Key hash (Wyhash, objects above 8 keys) | 0.33 M (4 %) | 0 | below 1 % |
| Strings (`string`, `key`) | 1.59 M (19 %) | below 1 % | 2.42 M (12 %) |
| Growth of the value stack | 0.55 M (7 %) | 3.34 M (3 %) | 1.27 M (6 %) |
| Collector per parse, in a loop | 0.73 M (9 % of the parse) | 21.1 M (18 %) | 4.1 M (20 %) |
| Heap bytes per JSON byte | 2.41 | 3.87 | 1.88 |

Facts from the profile:

- A string with no escape is already a slice of the input. String copies are not a cost: twitter, the file with the most escapes, has 328 allocations of a string.
- Canada has 101 338 doubles with 16 or 17 digits. Their mantissa is above 2^53, so the Clinger fast path fails, and `std.fmt.parseFloat` reads the text again. That parse of the text is two thirds of the conversion cost. The Eisel-Lemire step is one third.
- Each container is two allocations: the item buffer and the `ListObj`. Canada has 56 000 arrays of two numbers. Each costs 96 bytes of heap and 24 bytes in its parent for 2 values of 24 bytes.
- The value stack of the parser starts empty at each parse and grows by doubling. The append is a call that is not inline.
- The collector marks the live document at each collection. The cost is about one fifth of the parse for canada and citm.

### A script that reads the result

`bench/stdlib/json/read_ztcl.tcl` parses once and then runs a reader 50 times:

- twitter: a `foreach` over `statuses` with two `dict get`.
- citm: a `foreach` over `performances` and a `dict for`.
- canada: three nested `foreach`, and an `lassign` and an `expr` for each point.

In a flat `perf` profile of the canada reader, `vm.exec` has 57 %, `expr.binaryOp` 24 %, `expr.num` 12 %, and `shimmer` 5 %. The reader makes no allocation, so its cost is in the interpreter. The read of a field of a small dict is a linear search of at most 16 keys.

## The ideas

| Idea | Measured cost that it removes | Estimated gain | Risk | Decision |
|---|---|---|---|---|
| Direct Eisel-Lemire on the parsed mantissa | 2/3 of 33 % on canada | canada +30 % to +45 % | Low: one function, compared bit for bit with `std.fmt.parseFloat` | Task 01, done |
| An inline push on the value stack | The call of `ArrayList.append` for each value | +5 % to +10 % on all files | Low | Task 02, done |
| One block for each container | Half of the allocations | Measured: slower (see below) | Medium: more page faults | Task 03, after a heap change |
| Document arena | The rest of the allocation | Measured: slower (see below) | Medium: page faults and retention | Task 03, after a heap change |
| Interned keys | The key compare of the duplicate check | Below 3 % | Low | Part of task 05 |
| Dict shapes | The key slots of each record, the duplicate check | Memory: 24 bytes for each key of each record. Speed: small for the parse | High: each dict path, the list view, the JIT | Tasks 05 and 06, after a measure |
| Lazy numbers | The conversion of a number that no script reads | canada: up to the rest of the conversion | High: a new tag in each switch of the code and the JIT | Rejected for now |
| Lazy document | Each value that no script reads | Large for a script that reads a few fields | High: each value path | Rejected: `zt::json get` has this gain today |
| Zero-copy strings | Copies of plain strings | 0: done today | None | Done |

### What the first measures showed

Tasks 01 and 02 went in as planned. One block for each container and the arena were built and measured, and both are slower in time with fewer instructions:

| Runner, 200 parses of twitter.json | Page faults | Instructions |
|---|---|---|
| main | 10 064 | 1.79 G |
| One block for each container | 29 124 | 1.89 G |
| Arena of 64 KiB chunks | 45 649 | 2.07 G |
| Arena of 8 KiB chunks | 47 642 | 2.31 G |

`bench_ztcl.tcl parse` gave 612 MB/s for the arena and 803 MB/s for main on twitter, and 698 and 1004 MB/s on citm. The sweep gives each span with no live block back to the backing allocator (`Heap.freeSpan`). The likely cause of the faults: a parse of the next document maps the pages again, and each first touch of a page is a fault. Small blocks of one size class (the `ListObj` of main) leave a span empty less often than blocks of many sizes and chunks. This is not checked yet. Task 03 checks it. The collector also marked more bytes in each collection with the new layouts (the mark count of `markHit` went from 134 578 to 394 007 for 20 parses of twitter). The cause is not found. A test that cleared the free part of each chunk did not change the count.

So task 03 starts with a change of the heap: keep a small set of empty spans for reuse, with a cap that the memory limit counts. The arena is measured again after that change.

### 1. Document arenas

All containers of one parse come from large blocks of the heap: chunks of 64 KiB, and a block of its own for a buffer above 8 KiB. A pointer into a chunk keeps the whole chunk. A string of the input already keeps the whole input text, so the retention rule is the same as today. Rules:

- The arena is ordinary heap memory, so the counting allocator counts each byte, and the memory limit sees the full arena.
- A chunk has no free list. A value that a script makes later never goes in an arena.
- A list in an arena has `used == buf.len`, so `lappend` copies it. `lset` and `dict set` on an owned value write in place, as today.
- The step count of a parse does not change: a step is still one value.
- A deep copy to another thread copies the values. The arena stays in its heap.
- The mark of a chunk reads each word of the chunk, as for each block today.

Retention can be worse than today: a script that keeps one small dict of a large document keeps a chunk of 64 KiB. The memory gate of task 03 measures a loop that keeps one field of each parse.

### 2. Zero-copy strings

Done today. A string with an escape is a new block. This is 328 blocks for twitter.

### 3. Interned keys

The duplicate check of an object compares each key with the earlier keys (8 keys or fewer) or uses a table of Wyhash (more than 8). With dict shapes, a record with the same keys as the record before it compares each key with one key of the shape. A global table of short keys gives no gain that the profile can measure, and it needs a lock or one table per thread. Rejected.

### 4. Dict shapes

A shape is a key list and its index, shared by many dicts. A shaped dict holds the shape and a values array. The parse finds the shape of an object from the shape of the object before it in the same parent, so a list of records gets one shape.

- **A write of a new key** moves the dict to a child shape. Each shape keeps a small table of its transitions, so a loop that adds the same key to many dicts makes one child.
- **Deletion** turns the dict into a plain dict (a pair list). Deletion is rare in Tcl scripts.
- **Key order** is the order of the key list, so insert order holds.
- **The string form** is made from the key list and the values, with the same quotes as `listToString`. The bytes are equal to the string of the pair list.
- **The list view.** A dict is a list in Tcl. `lindex`, `llength`, `foreach`, and each other list command read the pairs. A shaped dict makes its pair list at the first list read and keeps it. This is the largest cost of the idea.
- **Copy on write and owned values** (`docs/jit.md`). A write to a shared shaped dict copies the values array only. An owned dict writes in place.
- **Threads.** A deep copy makes a plain dict on the other side, or copies the shape. A shape belongs to one heap.
- **The collector.** A shape is a heap block, and the dicts point to it. No change to the mark.
- **The step limit and the memory limit.** A shape counts in the memory of the heap like each block. A transition table pays steps for a long probe.
- **The JIT.** A shape check is one compare of a pointer. Tier 2 can load a field at a fixed offset after the check. The JSON task 05b has its own shape guards. They must go through the interface of the shape (`shapeOf`, `slotOf`) when this task lands.

Gain: the key slots (24 bytes for each key of each record) and the per-record duplicate check. Twitter and citm have records. Canada has arrays. The profile gives the duplicate check about 5 % on twitter and citm, so the speed gain of the parse is small. The memory gain is about 20 % of the values of twitter and citm by estimate. Shapes go after the tasks 01 to 03 and after a measure of dicts in TclOO objects, CSV rows, SQLite rows, and `dict create` of records.

### 5. Lazy numbers

A lazy number keeps the text and makes the double at the first use. Its string form must be the canonical form of the double, so `toStr` still needs the conversion, and a script that prints the value pays the same cost. It needs a new tag of `Value`, and each `switch` on the tag, the layout probe of the JIT, and the tier 2 guesses change. Task 01 removes two thirds of the conversion cost with no new tag. Rejected for now.

### 6. A lazy document

A value that makes its list and dict views at the first touch. `zt::json get` and `exists` already walk the index and make only the value at the path, and `bench/stdlib/json` measures them. A lazy value must also keep the input and the index alive and must count them in the memory limit. Rejected: the gain is in `get` today.

## Where else shapes help

- TclOO object variables: each object of a class has the same variable names.
- CSV rows of `zt::csv` with a header, and SQLite rows as dicts: each row has the keys of the header or the columns.
- `dict create` of records in a loop.

These cases need task 05 first. Each one measures its gain before it uses shapes.

## WebAssembly and AOT

The arena and the number code are plain Zig with no target code, so the wasm build uses them with no change. The wasm build collects only with precise roots. An arena chunk is a heap block, and the roots of a parse are the same as today. Shapes add a block kind that an AOT compiler (issue #40) can check with one compare, as the JIT does.

## Invariants

A test or a fuzzer checks each of these:

1. No change in any behavior that a script can see: the same results, errors, error codes, and error messages.
2. The `string` form of each value from a parse is byte-identical to the form on main. `tests/json` and `tools/json-fuzz.zig` compare the string form of a parse with a reference build of the pair list.
3. The step count of each script is the same, so `tools/jit-diff.sh` and the step limit sweeps give the same results.
4. Each double of a parse is bit-identical to `std.fmt.parseFloat` of its text. A unit test compares random numbers and the edges of the exponent range.
5. The memory count after a parse is equal to main or lower, and the memory limit stops a parse at the same chunk.
6. The suite in all modes, the thread tests, the collector stress, and the wasm smoke test pass as on main.
