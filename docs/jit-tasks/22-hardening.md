# Task 22: the hardening tests

## Goal

A test for each security rule of `docs/jit.md` that has no test yet.

## Files

- `src/jit/tests.zig`, `tools/jit-scan.sh` (new), `SECURITY.md`.

## The tests

1. **No script constant in code.** `tools/jit-scan.sh` runs a script whose procs use the integer literals 0x13371337 and 0x0BADC0DE in `expr`, `incr`, `set`, and a compare, with `--jit --jit-threshold 0 --jit-dump DIR` (a new flag: it writes each function to a file). No dump file has the byte sequence of either number, in either byte order.
2. **Bounds.** A proc with 2049 local variables, a proc with 32 769 bytecode instructions, and a proc with a word of 2049 parts stay in the interpreter (`failed` counts them) and give the output of the interpreter.
3. **The limits.** A script defines 100 000 procs and calls each one two times with `--jit --mem 2147483648`: it ends, `code_bytes + data_bytes` is at most the JIT limit, and the output equals the output without `--jit`.
4. **The entry check.** A unit test calls `jit.enter` with a `pc` out of range, a `pc` with an invalid entry, a wrong `sp`, and a frame with too few cells. Each call runs `exec`.
5. **No absolute address.** A unit test compiles one proc two times in two regions. The bytes of both functions are equal.
6. **The maps.** After the suite file `expr.test` runs with `-j`, no line of `/proc/self/maps` has `w` and `x` (a test command prints the check).
7. **The frame.** The JIT frame is at most 64 bytes on x86-64 Linux: a unit test reads the constant, and the prologue test of task 16 checks the stack pointer.
8. **Free.** After `reset`, `compact`, and `deinit`, the region of the interpreter is gone from `/proc/self/maps`.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-scan.sh                 # exit code 0
CAP tools/jit-diff.sh
```

## Must not change

The gates. If test 1 fails, the template that put the constant in code is a bug. Fix the template. Do not change the test.
