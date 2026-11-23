# Task 03: the roots, the mark, the sweep, and the stress mode

## Goal

The heap can collect: `heap.collect(it)` marks each block that a root reaches and frees the others. In this task, only the stress mode and a test call start a collection.

## Files

- `src/heap.zig`: `collect`, the mark stack, the sweep.
- `src/gc.zig` (new): the roots of an interpreter, and the capture of the registers.
- `src/interp.zig`: the fields `gc_stress: u32 = 0` and `gc_count`. No other change.
- `src/main.zig`: the flag `--gc-stress N`. `tools/suite.sh`: the option `-g N` passes it.
- `src/tests.zig`: the tests below.

## The mark

- A word is a candidate when it is aligned to 8 bytes and its value is inside a page of the heap. The block of that address gets its mark bit, and its bytes go on the mark stack.
- The scan of a block reads each aligned word of the block. A block of a class of at most 16 bytes with no pointer is still scanned.
- A large block of bytes (a string above 8 KiB) has a flag `no_scan`. `it.allocBytes` sets it. Each string allocation of `Value` text uses it. A coroutine stack must not have this flag.
- The mark stack is memory of the embedder allocator, outside the heap and outside `mem_limit`. If it cannot grow, the collection stops and frees no block.

## The roots

1. Each byte range of the `Interp` struct.
2. The native stack from the stack pointer of `collect` up to `it.native_base`. When `it.nest` is zero, there is no stack range.
3. The callee-saved registers. A small assembly routine for each target pushes them before the scan: `rbx`, `rbp`, `r12` to `r15` on x86-64 (also `rdi`, `rsi`, and `xmm6` to `xmm15` on Windows), and `x19` to `x30` on arm64. The routine is in `src/gc.zig`. On a target with no routine, also WebAssembly, the collector is off.
4. For each coroutine that is suspended: the range from its saved stack pointer to the top of its stack. The running coroutine uses rule 2 with its own base, and the stack of its resumer from the saved pointer of the resumer.
5. Each child interpreter of `it.children`, with rules 1 to 4.
6. Each range of `it.gc_roots`, which the embedder fills (task 04).

WebAssembly has no way to read the native stack. Its build keeps the heap with no collection. Say so in `docs/design.md`.

## The sweep

A block with no mark goes to the free list of its class. In a build with safety checks, the sweep fills it with the byte 0xDD. A page with no live block goes back to the counting allocator.

## The stress mode

With `gc_stress` N above zero, each Nth allocation calls `collect` first. The stress mode is the main defense against a missed root: with N of 1, a value that no root holds dies before its first use, and the 0xDD fill makes the use visible.

## Acceptance

```sh
CAP zig build test
CAP zig build test -Doptimize=ReleaseSafe
CAP zig-out/bin/ztcl --gc-stress 1 bench/fib.tcl          # 75025
CAP sh -c 'for f in bench/*.tcl; do zig-out/bin/ztcl --gc-stress 64 $f; done'   # the outputs of today
CAP tools/suite.sh -g 64            # a new option: passes --gc-stress 64. pass 19877
CAP tools/suite.sh -g 1 set.test incr.test list.test dict.test string.test coroutine.test oo.test trace.test upvar.test uplevel.test
```

New unit tests, each in the stress mode with N of 1:

- A value in a variable, in a list, in a dict, in an array, and in a namespace variable survives.
- A value on the word stack during a command survives.
- The result of a command survives until the next command.
- A suspended coroutine keeps its locals.
- A child interpreter keeps its values. A deleted child loses them.
- A traced variable, an `upvar` link, and an element link survive.
- A compiled script, a compiled expression, and the caches survive or are made again.
- A string that is a part of a larger buffer keeps the buffer.
- After a loop of one million new strings, `collect` brings `memUsed` back to within 1 MiB of the start.

## Must not change

With `gc_stress` zero, no collection runs, and each instruction count stays inside the gate of task 02.
