# Task 02: the heap in place of the arena

The user must accept open decision 0 of `docs/jit.md` before this task starts.

## Goal

`it.alloc()` returns an allocator of a new heap with size classes. Nothing is collected yet: memory still goes back only at `compact`, `reset`, and `deinit`. This task proves the cost of the heap alone.

## Files

- `src/heap.zig` (new).
- `src/interp.zig`: the field `arena` becomes the heap. `alloc`, `init`, `reset`, `deinit`, and `memUsed` use it. `Counting` stays between the heap and the allocator of the embedder.
- `src/compact.zig`: it copies to a new heap and frees the old heap.
- `src/coro.zig` is not in this task. A coroutine stack is one large block from `it.alloc()` as today.

## The heap

- Pages of 64 KiB from the counting allocator. One page has blocks of one size class.
- Size classes: 16 bytes, then steps of 16 up to 128, then four classes for each power of two up to 8 KiB. A larger request is a large block of whole pages.
- Each page has a header outside the block area: the class, the count of blocks, a mark bitmap, and a free bitmap.
- A sorted table of the pages gives the page of an address in O(log n). A pointer into the middle of a block gives the block.
- `alloc` gets a block from the free list of the class, or a new block of the current page. `resize` in place succeeds only inside the size of the class. `free` is a no-op in this task.
- `append` to a string and `lappend` use spare room after a value. Keep both fast: `Interp.appendStr` reads the room of the block from the heap (`heap.roomAfter(ptr)`), and its table `tails` goes away if the heap gives the same answer.
- The heap is not thread safe. One interpreter has one heap.

## Acceptance

```sh
CAP zig build test            # new tests: each class, large blocks, the address lookup,
                              # a lookup of an address outside the heap, resize, reset
CAP tools/suite.sh            # pass 19877
CAP zig build && for f in bench/*.tcl; do CAP perf stat -e instructions:u zig-out/bin/ztcl $f; done
CAP zig build bench           # the fast path stays at about 15 ns for each point, same sum: true
CAP zig build wasm && node tools/wasm-smoke.mjs
```

Gate: each script of `bench/` uses at most 3 % more instructions than the baseline of task 01. The peak memory of each script of `bench/` is at most 1.25 times the peak of the arena.

## Must not change

Each result of each script. The public names of `Interp`. The rule that all memory of an interpreter comes through `Counting`.
