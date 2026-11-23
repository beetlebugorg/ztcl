# Task 20: the assembler and verifier fuzzers

## Goal

Random tests of the two parts that turn data of a script into machine code.

## Files

- `tools/jit-fuzz.zig`: the modes `--asm` and `--verify`.
- `tools/jit-asm-golden.sh`: the option `--random N`.

## The assembler

`tools/jit-asm-golden.sh --random N` makes N random instructions from the forms of task 12 with random registers, displacements, and immediates, assembles them with `zig cc -c`, and compares each one with the bytes of `src/jit/x64.zig`. Task 26 adds the same for arm64.

## The verifier

`--verify` makes `Code` values in two ways: random instructions, and the `Code` of a random program of task 19 with 1 to 4 random changes of an operand or an opcode. For each one:

1. `verify` runs. It must not crash.
2. If `verify` accepts the `Code`, the tool compiles it, makes a frame with `names.len` cells, and runs it with a step limit of 10 000, in a `ReleaseSafe` build. The process must not crash, and no safety check of Zig can fail.

A `Code` that the verifier accepts can still run a general command with strange words. That is correct: the general path handles each word.

## Acceptance

```sh
CAP tools/jit-asm-golden.sh --random 1000000
CAP zig build jit-fuzz -Doptimize=ReleaseSafe -- --verify --count 1000000
```

Both end with code 0. Report the share of random `Code` values that the verifier accepts. If it is below 1 %, improve the generator, so that the second step runs often.

## Must not change

The checks of task 14 can only become stricter.
