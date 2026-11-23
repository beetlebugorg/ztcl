# Task 19: the random program fuzzer

## Goal

A tool that makes random Tcl programs and compares the interpreter with each JIT mode.

## Files

- `tools/jit-fuzz.zig` (new), `build.zig` (the step `jit-fuzz`), `tests/jit/found/` (new: each program that found a bug).

## The generator

- A seed gives one program. The same seed gives the same program on each run.
- The grammar: 1 to 6 procs with 0 to 4 parameters; `set`, `incr`, `expr` with each operator and integer, double, and string operands; `if`, `while`, `for`, `foreach` with one to three variables; `break`, `continue`, `return` with and without `-code`; `lappend`, `lindex`, `llength`, `lset`, `lassign`, `list`; `dict set`, `dict incr`, `dict get`; `append`, `string length`, `string index`; `switch`; `catch`, `try`, `error`; `upvar`, `uplevel`, `global`, `eval`; `rename` of a core command and of a proc, and back; `trace add variable`; `unset`; a coroutine with `yield`; `apply`; a namespace with a proc of the name of a core command.
- Integer constants favor 0, 1, -1, the 32-bit and 64-bit limits, and their neighbors.
- Each loop has a bound of at most 50 passes, and each program has a step limit, so each program ends.
- A program prints each result with `puts`, also each caught error message, `errorCode`, and the first line of `errorInfo`.

## The run

For each seed, in one process: the program runs in a new interpreter with no JIT, with threshold 0, and with the default threshold. Then again with a step limit of a random part of the full count, and with a random memory limit with the collector off. The tool compares the output, the result or the error, `errorInfo`, `errorCode`, the steps left, and `memUsed`. A difference writes the seed and the program to a file and ends with code 1.

Options: `--seed N`, `--count N`, `--seconds N`, `--tier2`, `--stress N`.

## Acceptance

```sh
CAP zig build jit-fuzz -- --count 200000          # exit code 0
CAP zig build jit-fuzz -Doptimize=ReleaseSafe -- --seconds 3600
```

- A test of the fuzzer itself: with a planted bug (a build flag `-Djit_bug=true` makes the `bin_vv` template skip the overflow check), the fuzzer finds a difference in at most 100 000 programs. Remove no part of this check after the task.
- Report the count of programs, the mean count of bytecode instructions, and the share of programs that reached each grammar item.
- Fix each difference that the run finds, and add its program to `tests/jit/found/`.

## Must not change

The gates of task 17.
