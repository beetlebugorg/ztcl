# Task 29: x86-64 Windows

## Goal

Tier 1 on Windows. This task needs a Windows machine. Rebase on the port branch that has `coro.zig` and `sys_windows.zig` first.

## Files

- `src/jit/mem.zig`, `src/jit/abi.zig`, `src/jit/tier1_x64.zig` (the ABI comes from `abi.zig`), `src/jit/unwind_win.zig` (new), `src/gc.zig`, `src/jit.zig`.

## The memory calls

Declare each function with `extern "kernel32"` in `mem.zig`.

- `init`: `VirtualAlloc(null, limit, MEM_RESERVE, PAGE_NOACCESS)`.
- `append`: `VirtualAlloc(pages, MEM_COMMIT, PAGE_READWRITE)`, copy, fill with 0xCC, `VirtualProtect(pages, PAGE_EXECUTE_READ)`, `FlushInstructionCache(GetCurrentProcess(), start, len)`.
- Never use `PAGE_EXECUTE_READWRITE` or `PAGE_EXECUTE_WRITECOPY`.
- `deinit`: remove the function table, then `VirtualFree(base, 0, MEM_RELEASE)`.
- A process with the dynamic code policy (ACG) refuses `VirtualProtect`. Then `init` or the first `append` fails, and the JIT is off.

## The ABI

- Arguments of a helper: `rcx`, `rdx`, `r8`. Each call has 32 bytes of shadow space below the return address.
- `rsi` and `rdi` are callee-saved. The templates must not write them. On System V they hold arguments, so `abi.zig` names the argument registers, and no template names `rdi` or `rsi` directly.
- The frame: `push rbp`, `mov rbp, rsp`, push `rbx`, `r12` to `r15`, `sub rsp, 48` (the context slot, the shadow space, and the alignment). The frame is below one page, so the code has no `__chkstk` call.
- The helpers are Zig functions with `callconv(.c)`. On this target, that is the Microsoft x64 convention.

## The unwind data

- Each compiled function gets one `RUNTIME_FUNCTION` and one `UNWIND_INFO` with the codes of the fixed prologue: `UWOP_PUSH_NONVOL` for `rbp`, `rbx`, `r12` to `r15`, `UWOP_SET_FPREG`, and `UWOP_ALLOC_SMALL`.
- The records are in the region, in a read-only page after the code of the function, because the offsets are relative to one base address.
- `RtlAddFunctionTable` registers the record after the pages are executable. `RtlDeleteFunctionTable` removes it at `flush`.
- A test calls `RtlLookupFunctionEntry` for an address inside a compiled function and gets the record. A second test calls `RtlCaptureStackBackTrace` inside a helper that compiled code called: the trace has the frame of the test above the JIT frame.

## Acceptance

On Windows:

```sh
zig build test && zig build test -Djit=false
tools/jit-diff.sh && tools/jit-diff.sh --stress     # with a POSIX shell, or a port of the tool
zig build jit-fuzz -- --count 200000
```

- A test calls `VirtualQuery` on each page of the region after two compiles: each page is `PAGE_EXECUTE_READ`, `PAGE_READONLY`, or not committed.
- A coroutine test: a compiled proc yields and resumes 1000 times.
- The time gate of task 27.
- Use a job object or a small machine for the memory cap, and report what you used.

## Must not change

The results of the other targets. `src/coro.zig`, `src/sys_windows.zig`.
