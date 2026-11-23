# Task 11: executable memory on Linux

## Goal

A region that holds machine code, with no page writable and executable at once.

## Files

- `src/jit/mem.zig` (new), `src/jit/tests.zig` (new, in the test block of `src/ztcl.zig` when `jit.built`).

## Contract

```zig
pub const Region = struct {
    /// Reserves `limit` bytes of address space with no access, plus one
    /// page with no access before and after. Null when the system refuses.
    pub fn init(limit: usize) ?Region;
    pub fn deinit(r: *Region) void;
    /// Copies `code` to new pages and makes them executable. Null when the
    /// region is full or a system call fails. After null from a failed
    /// system call, each later call returns null.
    pub fn append(r: *Region, code: []const u8) ?[]const u8;
    pub fn usedBytes(r: *const Region) usize;
};
/// Makes a function that returns 42 and calls it.
pub fn selfTest() bool;
```

## Rules

1. `init`: `mmap` with `PROT_NONE`, private and anonymous, with `MAP_NORESERVE`.
2. `append`: the function starts on the next free page. `mprotect` the pages that it needs to read and write. Copy the code. Fill the rest of the last page with 0xCC. `mprotect` the same pages to read and execute. Return the slice.
3. A page that is executable never gets `PROT_WRITE` again. No call ever asks for write and execute together.
4. If the second `mprotect` fails, set the pages back to `PROT_NONE` and stop the region.
5. Each address and length comes from the fields of the region. Check `used + pages <= limit` with overflow-safe math before each call.
6. The region counts whole pages in `usedBytes`. The caller checks the JIT memory limit.
7. Use `std.os.linux` or `std.posix` of Zig 0.16.0. Add no libc.

## Acceptance

```sh
CAP zig build test
```

New tests:

- `selfTest` returns true.
- After two `append` calls, the test reads `/proc/self/maps` and finds the region. No line of the whole file has both `w` and `x`. The used pages have `r-xp`, and the rest and both guard pages have `---p`.
- A write to a returned slice is not possible: the test does not write. It checks the rights from the maps file.
- `append` of more than the limit returns null and leaves the earlier functions callable.
- A child process sets `prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN)` and then calls `selfTest`: the result is false and the process does not crash. Skip the test when the kernel does not know the option.
- The last page of a function has 0xCC after the code.

## Must not change

No file outside `src/jit/` and the test list of `src/ztcl.zig`.
