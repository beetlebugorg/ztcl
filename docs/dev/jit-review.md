# Review checklist for the memory work and the JIT

This list is for the reviewer of each task of [the task list](jit-tasks/README.md). [The design](jit.md) gives the reasons. Check the security items first. An item that does not apply to a task gets "not in this task".

The reviewer runs the acceptance commands of the task again, under the memory cap, one at a time. The numbers in a PR body are not a proof.

## 1. Security

### Executable memory

- [ ] No call asks for write and execute rights together. Search for `PROT_EXEC`, `PAGE_EXECUTE`, and `MAP_JIT`: each use is in `src/jit/mem.zig`.
- [ ] `PAGE_EXECUTE_READWRITE` and `PAGE_EXECUTE_WRITECOPY` appear nowhere.
- [ ] On Linux, Windows, and an Intel Mac, a page that is executable never gets a write right again.
- [ ] On Apple silicon, the write switch is off only around one copy. No other code runs between the two switch calls.
- [ ] No page is mapped two times.
- [ ] The instruction cache is flushed for the exact range before the first run on arm64 and on Windows.
- [ ] The guard pages and the fill bytes exist, and a test reads them.
- [ ] `flush` runs at `reset`, `compact`, and `deinit`, and no native frame can return into freed code. Check the coroutine case and the child that is deleted while it runs.
- [ ] Each failure of a memory call turns the JIT off or stops the compiler. No failure is an error of a script, and no failure can crash the host.

### The instruction stream

- [ ] No value of a script is an immediate operand. Read each template: each literal comes from `code.lits`.
- [ ] No absolute address is in the code. Helper calls go through the table register.
- [ ] Each number in an instruction that a script can influence has a bound from the verifier limits.
- [ ] The assembler returns an error for a value that does not fit its field. No encoder wraps or truncates a value.
- [ ] Each label is bound, and each branch offset is checked against its range.
- [ ] `tools/jit-scan.sh` passes.

### The verifier and the entry

- [ ] Each fact that a template relies on is a check of `src/jit/verify.zig`. For each template, name the check.
- [ ] A new bytecode instruction has a verifier row, a helper, a template or a helper call, and a differential test.
- [ ] `jit.enter` checks `pc`, the entry, `sp`, the target range, and the size of the frame.
- [ ] `jit.deopt` and `jit.tierUp` check each index and each address that comes from machine code.
- [ ] The entry table and the exit records are outside the executable pages, and a wrong value in them cannot move control outside the function.

### Guards

- [ ] Each inline path checks the cell tag and the value tag before it reads a payload, with the mask of the layout.
- [ ] No inline path trusts a tag across a helper call.
- [ ] Each list index has an unsigned compare with the length of the view.
- [ ] `+`, `-`, `*`, and `incr` check the overflow. A division checks zero and the overflow case.
- [ ] A fast path has no effect before its last check.
- [ ] In tier 2, each register is written to its cell before a call that can run a script, and each guess is checked again after it.
- [ ] `x18` is never used on arm64. `rsi` and `rdi` are never written by a template on Windows.

### The limits

- [ ] The step count of each test script is equal with and without the JIT. The compute limit sweep passes.
- [ ] A joined step check in tier 2 exits at the start of its part with no step used, and each exit gives the unused steps back.
- [ ] The memory limit check is at the same instructions as in the interpreter. With `--gc off`, a script stops at the same point in both modes.
- [ ] The memory of the JIT is outside `mem_limit` and inside `jit_mem_limit`. `memUsed` is equal with the JIT on and off.
- [ ] `max_depth`, `max_nest`, and `max_native` are checked by the functions of today. The JIT frame has a fixed size, and the native stack of one call level is not larger than in the interpreter.
- [ ] The compute limit error and the memory error stay uncatchable.

### The sandbox

- [ ] The JIT adds no command, no capability, and no host access. The test that each capability is absent by default still passes.
- [ ] A script cannot turn the JIT on, and cannot read if it is on.
- [ ] A child interpreter has the JIT only when its parent has it.
- [ ] The default is on in the library and in the runner, and `--no-jit`, `ZTCL_JIT=off`, and `disableJit` turn it off. A system that refuses executable memory runs the interpreter with no error.
- [ ] The WebAssembly build has no JIT code.
- [ ] With the JIT on, the output of a script is equal to the output with the JIT off. Rule 4 of AGENTS.md.

## 2. The collector (tasks 02 to 06)

- [ ] The roots: the `Interp` struct, the native stack, the callee-saved registers, each coroutine stack, each child, and the ranges of the embedder. Name the code of each one.
- [ ] A pointer into the middle of a block keeps the block. A test proves it for a string that is a part of a buffer.
- [ ] No block that can hold a pointer has the `no_scan` flag. Check each call of `allocBytes`.
- [ ] No pointer to a heap block is stored outside the heap and the roots: search for hidden forms (a pointer as an integer with changed bits, a pointer in memory of the embedder allocator).
- [ ] The data of the JIT holds no pointer that must keep a block.
- [ ] The stress mode with N of 1 runs the unit tests in a build with safety checks, and the fill pattern is in place.
- [ ] A collection cannot start inside `compact`, and cannot start while the mark stack is in use.
- [ ] The trigger reads no clock and no address.
- [ ] The embedder rule is in `docs/embedding.md`, and `hold` has a test.
- [ ] The memory tests are flat, and the outside programs end with the output of `tclsh`.

## 3. Correctness

- [ ] The interpreter and the helpers run one function for each instruction. List each handler that task 15 left as a copy, and check that copy line by line.
- [ ] The order of the checks and the effects inside each template equals the interpreter. Read the template next to the function.
- [ ] `errorInfo`, `errorCode`, and the error line are equal in both modes for each error test.
- [ ] `break`, `continue`, `return -code`, `tailcall`, and custom codes pass through compiled code.
- [ ] A redefined command, a variable trace, `upvar`, `uplevel`, and `unset` inside a running compiled proc have a test each.
- [ ] A coroutine yields from compiled code and resumes. `src/coro.zig` did not change.
- [ ] The point proc tests pass, and both paths are equal bit for bit.
- [ ] Tier 2 has no fused multiply-add and no x87 code.

## 4. Tests and gates

- [ ] `zig build test` and `zig build test -Djit=false` pass.
- [ ] `tools/suite.sh` and `tools/suite.sh -j` give 19 877, and each file is equal. At the end of a milestone: 37 383 for all 152 files in both modes.
- [ ] `tools/jit-diff.sh` passes, also with `--stress`.
- [ ] The fuzzers ran for the count of the task, and each found program is in `tests/jit/found/`.
- [ ] The planted bug test of the fuzzer still finds its bug.
- [ ] `tools/jit-perf.sh --check off` passes: the interpreter did not slow down.
- [ ] Each gate of the task passes, or the PR has the measured number and the cause. No gate changed without a recorded reason.
- [ ] Each number in the docs is a number that someone measured. An estimate has the word "estimate".

## 5. Project rules

- [ ] No dependency. No code from another project. No source of a GPL or AGPL project was read for the work.
- [ ] Each new idea has its source in `docs/references/jit.md`.
- [ ] Each new file has the `//!` header and the SPDX line.
- [ ] The diff does not touch `src/coro.zig`, `src/sys.zig`, `src/sys_windows.zig`, `src/fsroot.zig`, or `src/proc.zig`. The hunks in `src/interp.zig`, `src/main.zig`, and `src/ztcl.zig` are those of the task.
- [ ] The text follows WRITING.md. The words "compute limit" name the limit on steps.
- [ ] No AI model or vendor is named. No attribution line is in a commit or a file.
- [ ] No local path and no private data is in the repository.
- [ ] The commits rebase on `main` with no merge commit.
