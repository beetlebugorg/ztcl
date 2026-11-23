# Task 16: tier 1 with a helper call for each instruction

## Goal

The first working compiler. Each bytecode instruction becomes a call of its helper and an inline jump. This task proves the entry, the exit, the errors, and the control flow. It has no inline fast path yet.

## Files

- `src/jit/abi.zig` (new): the pinned registers, the scratch registers, and the argument registers of the target.
- `src/jit/tier1.zig` (new): the driver. `src/jit/tier1_x64.zig` (new): the code for x86-64.
- `src/jit.zig`: `maybeCompile`, `enter`, the `Fn` record, the counts.
- `src/vm.zig`: the hook in `run`.

## The context

```zig
pub const EnterCtx = extern struct {
    it: *Interp, code: *const vm.Code, frame: *Frame, stack: [*]Value,
    helpers: [*]const *const anyopaque,
    target: usize,       // the address to jump to
    pc: u32, sp: u32,    // out
    err: u16,            // out: @intFromError
};
```

## The function

- Signature: `fn (ctx: *EnterCtx) callconv(.c) u32`. The result is 0 (done: the value is at `stack[ctx.sp - 1]`), 1 (error), or 2 (run `exec` at `ctx.pc` and `ctx.sp`).
- Prologue: push `rbp`, set `rbp`, push `rbx`, `r12`, `r13`, `r14`, `r15`, store the context pointer at `[rbp - 48]`, load the five pinned registers from the context, and `jmp [ctx.target]`. The stack pointer is 16-byte aligned at each call. The frame is at most 64 bytes.
- One epilogue: it pops the registers and returns `eax`.
- For each reachable instruction, in order: record its offset in the entry table, then emit `mov rdi, [rbp - 48]`, `mov esi, pc`, `mov edx, depth`, `call [r12 + 8 * helper]`, `cmp eax, 1`, `ja` to the error stub of this instruction.
- An instruction with two successors adds `je` to the code of its target. `jump` is one `jmp`. `guard` jumps to its cold block when the helper returns 1.
- `ret` writes the depth to `ctx.sp`, sets `eax` to 0, and jumps to the epilogue.
- The error stub of an instruction writes its `pc` and its depth to the context, sets `eax` to 1, and jumps to the epilogue. The stubs are after the last instruction.
- An unreachable instruction has no code. Its entry is invalid.

## `maybeCompile` and `enter`

- `vm.run` calls `jit.maybeCompile(it, code)` when `it.jit` is not null and `code.jit_state` is `.untried`. It counts the call. It compiles when the count reaches the threshold, or at the first call when `Info.has_loop` is true.
- A failed verify, an allocation failure, a full region, or a reached JIT memory limit sets `.failed`. No failure is an error of the script.
- `enter` checks `pc < ins.len`, that the entry of `pc` is valid, that `sp` equals the depth of `pc`, that `target` is inside the function, and that `it.frame.vars.items.len >= code.names.len`. A failed check runs `exec`.
- `enter` turns status 1 into the Zig error of `ctx.err`, after it writes `pc` and `sp` back for `run`.
- The `catch` block of `run` does not change.

## Acceptance

```sh
CAP zig build test
CAP sh -c 'for f in bench/*.tcl; do zig-out/bin/ztcl --jit --jit-threshold 0 --jit-stats $f; done'
CAP tools/suite.sh -j                 # pass 19877, and each file equals its count without -j
CAP tools/jit-perf.sh --check off
```

- Each benchmark prints the output of the interpreter, and `compiled` is at least 1 with `failed` 0.
- New unit tests, each with threshold 0 and compared with the interpreter: an error in a proc with the full `errorInfo`; `break` and `continue` from `eval` inside a compiled loop; `return -code` of each code; `catch` around a compiled proc; a step limit that ends inside a compiled loop, with the same steps left; a coroutine that yields from a compiled proc and resumes; `rename set foo` inside a running compiled proc; a variable trace added while a compiled loop runs; `upvar` and `uplevel` that change a local of a compiled proc; a proc that redefines itself; `tailcall`; a TclOO method.
- Report the instruction count of each benchmark with `--jit`. This task has no gate for them.

## Must not change

The instruction counts with no flag (1 %). The pass counts. `src/coro.zig`.
