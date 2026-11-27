# Task 01: memory tests and the outside benchmark tool

## Goal

Make the tests and the tools that show the memory growth, before any change to the interpreter. Each test fails today.

## Files

- `tests/mem/*.tcl` (new): one script for each row below. Each script reads the pass count from `argv`.
- `tools/mem-flat.sh` (new): runs each script with N and with 10 N passes and prints the peak of `memUsed` for both.
- `tools/fetch-kostya.sh` (new): gets `kostya/benchmarks` at commit `5bc68b3705` into the ignored folder `.kostya/`, as `tools/fetch-tcl.sh` does for Tcl. Add `.kostya/` to `.gitignore`.
- `tools/kostya.sh` (new): runs `bf.tcl bench.b`, `bf_oo.tcl bench.b`, and `base64/test.tcl` on ztcl and on a `tclsh`, in the memory cap. It prints the output, the instruction count, and the peak memory of each run, and the ratio of the counts.
- `src/cli/main.zig`: the flag `--report`. At the end, the runner writes one line to stderr: `report compute=<used> mem=<bytes now> peak=<highest bytes>`.
- `src/interp.zig`: the field `mem_peak` of `Counting`, set in its `alloc` and `resize`.
- `docs/references/jit.md`: the entry for `kostya/benchmarks` exists. Check it.

## The memory scripts

| Script | Body of one pass |
|---|---|
| `lset.tcl` | `lset tape 3 5` on a list of 100 items |
| `pass.tcl` | `lassign [f $tape $pos] tape pos`, where `f` returns `[list $tape $pos]` |
| `lassign.tcl` | `lassign $x op val` |
| `switch.tcl` | `switch -exact -- $op {INC {incr s} MOVE {incr s 2}}` |
| `method.tcl` | a call of a TclOO method that adds to a variable of the object |
| `b64enc.tcl` | `string length [binary encode base64 $str]` with 131 072 bytes |
| `b64dec.tcl` | `string length [binary decode base64 $enc]` |
| `append.tcl` | `set s x$i` (a new string for each pass) |
| `list.tcl` | `set l [list $i $i $i]` |
| `dict.tcl` | `set d [dict create a $i]` |
| `proc.tcl` | a call of a proc that returns `[string repeat x 100]` |
| `coro.tcl` | a coroutine that yields one new string for each pass |

## Rules for the outside programs

- Do not change a benchmark file. The repository has no copy of them.
- `bf.tcl` prints a checksum only when `::env(QUIET)` exists. `tools/kostya.sh` makes it exist for ztcl and for `tclsh` in the same way, with no change to the file. Use the environment rule of `exec` or a first script that sets the variable and then runs the program. Write in the tool which way it uses.
- The programs call `socket localhost 9001` inside `catch`. No server is there. Keep the network policy `loopback`.
- Run ztcl with `--compute 100000000000 --allow package,interp,clock,channels,file,event,socket,exec --root <folder> --tclsh <script> <args>`.
- `matmul` is not a gate. It needs `math::linearalgebra` of tcllib.

## Acceptance

```sh
CAP zig build
CAP zig build test
CAP tools/mem-flat.sh            # prints a table. Each row shows growth today. Exit code 1.
CAP tools/kostya.sh --only base64 --mem 6442450944   # ends, prints both outputs and the ratio
CAP tools/suite.sh               # pass 19877
```

Record in the PR body the bytes for each pass of each script. `docs/dev/jit.md` has the numbers of 2026-11-23 for seven of them: 2460, 127, 30, 128, 125, 242 KiB, and 168 KiB. If a number differs by more than 10 %, report it.

## Must not change

The instruction count of each script of `bench/` (at most 0.2 % more). The output of each test.
