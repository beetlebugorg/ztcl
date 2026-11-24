# Testing and benchmarks

Run each command under a memory cap. On Linux with systemd:

```sh
systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- <command>
```

## Unit tests

```sh
zig build test
```

## The Tcl suite

The test files of the Tcl source measure compatibility. The repository has no copy of them. `tools/fetch-tcl.sh` downloads a release into the ignored folder `.tcl-src/`.

```sh
zig build
tools/suite.sh                        # the 37 core files of core-8-6-16
tools/suite.sh -a                     # all 152 files
tools/suite.sh -t <tag>               # another Tcl release
tools/suite.sh -s <tcl source>/tests  # a local folder
tools/suite.sh set.test expr.test     # some files
```

`tools/tcltest.tcl` is a small stand-in for the `tcltest` package. It evaluates the constraints in the three forms of `tcltest`, and it checks `-output`, `-errorOutput`, and the `exact`, `glob`, `regexp`, and custom match modes. A failed cleanup is a failure. A test with a false constraint counts as skipped, and the log records the constraint. `tools/tcltest-end.tcl` prints the counts after each file.

`tools/suite-count.tcl` counts the tests of a file with a real `tclsh`, in a safe interpreter. `tools/suite-scope.tsv` has the count and the scope of each file.

`zig build suite-runner` builds `zig-out/bin/ztcl-suite`, the runner with the test commands of `tools/suite_cmds.zig`: `testregexp`, `testevalex`, and the `testexpr` commands. Each one calls real ztcl code. The library, the default runner, and the WebAssembly build do not have them.

`tools/suite.sh` gives each test file a fresh root folder with a copy of the support scripts of the Tcl tests, and it deletes that folder after the file. It turns on each capability: `package`, `interp`, `clock`, `channels`, `file`, `event`, `socket`, and `exec`. The suite stays offline and inside the root folder:

- `socket` has the `loopback` policy.
- `exec` runs only the programs of a fixed list (`cat`, `echo`, `sh`, `sleep`, and others), with the root folder as the working folder, an environment of `PATH`, `HOME`, and `LANG` only, and a time limit of 120 seconds.
- The `tclsh` of the tests is the script `ztclsh` in the root folder. It runs the same runner with `--tclsh`.
- A test file has a time limit of 20 minutes. Some files wait on timers: `main.test` and `socket.test` use some minutes each.

To make the table, run the suite with both runners:

```sh
tools/suite.sh -a -o plain.tsv
tools/suite.sh -a -r zig-out/bin/ztcl-suite -o full.tsv
python3 -I tools/suite-table.py full.tsv plain.tsv > docs/compatibility.md
```

[Compatibility](compatibility.md) has the table for all 152 files. A test that did not run counts as blocked. It does not count as a pass.

### Results with Tcl 8.6.16 (`core-8-6-16`), the 37 core files

With the same stand-in, the commit before this work has 19 291 pass, 1 013 fail, and 525 skip.

| File | Pass | Fail | Skip |
|---|---|---|---|
| `set.test` | 61 | 2 | 1 |
| `incr.test` | 62 | 4 | 0 |
| `if.test` | 73 | 0 | 0 |
| `while.test` | 45 | 1 | 0 |
| `for.test` | 61 | 3 | 24 |
| `foreach.test` | 41 | 2 | 0 |
| `proc.test` | 26 | 3 | 9 |
| `uplevel.test` | 49 | 8 | 0 |
| `upvar.test` | 43 | 14 | 8 |
| `expr.test` | 14122 | 14 | 49 |
| `list.test` | 77 | 1 | 0 |
| `lindex.test` | 44 | 2 | 37 |
| `llength.test` | 6 | 0 | 0 |
| `lrange.test` | 32 | 0 | 2 |
| `linsert.test` | 28 | 0 | 0 |
| `lreplace.test` | 1787 | 0 | 0 |
| `lsearch.test` | 111 | 7 | 0 |
| `join.test` | 10 | 0 | 0 |
| `split.test` | 16 | 1 | 0 |
| `concat.test` | 9 | 0 | 0 |
| `append.test` | 42 | 3 | 0 |
| `string.test` | 620 | 4 | 10 |
| `format.test` | 255 | 2 | 9 |
| `switch.test` | 106 | 7 | 0 |
| `eval.test` | 11 | 1 | 0 |
| `parse.test` | 88 | 2 | 181 |
| `lmap.test` | 62 | 4 | 0 |
| `apply.test` | 33 | 5 | 4 |
| `rename.test` | 10 | 1 | 8 |
| `error.test` | 300 | 9 | 8 |
| `lset.test` | 0 | 0 | 89 |
| `namespace.test` | 235 | 75 | 3 |
| `regexp.test` | 240 | 1 | 3 |
| `binary.test` | 602 | 36 | 79 |
| `info.test` | 97 | 164 | 5 |
| `dict.test` | 311 | 29 | 2 |
| `scan.test` | 162 | 18 | 1 |
| **Total** | **19877** | **423** | **532** |

The largest groups of tests that still fail in scope: `info frame`, step traces, the bytecode tools (`tcl::unsupported::disassemble`), the slots and the rest of TclOO, and the details of `namespace`.

## Memory tests

| Command | What it checks |
|---|---|
| `tools/mem-flat.sh` | Each script of `tests/mem` holds a flat peak from N to 10 N passes. |
| `node tools/wasm-mem.mjs zig-out/lib/ztcl.wasm` | The same check on WebAssembly. `--browser <path>` runs it in Chromium or Firefox. `--stress` compares a run with a collection at each safe point. |
| `tools/suite.sh -g N` | The suite with a collection at each Nth safe point and allocation. A freed block is poisoned. |
| `tools/gc-fuzz.py -r <runner>` | Random programs with a collection at each safe point and allocation, compared with `--gc off`. |
| `zig build suite-runner -Dgc-precise=true -Drunner-optimize=ReleaseSafe` | A runner with the root rules of WebAssembly and safety checks, for the two commands above. |
| `tools/kostya.sh` | The outside programs against `tclsh`. The table is in [the JIT plan](jit.md#results-of-milestones-0-and-b). |

`cmdMZ-6.6` compares wall-clock times of `timerate`. It fails with `-g 64` on a native runner, because the stress mode slows each allocation. It passes without stress and with the precise runner at `-g 64`.

## JIT tests

| Command | What it checks |
|---|---|
| `zig build test` and `zig build test -Djit=false` | The unit tests with and without the JIT code. `src/jit/tests.zig` runs scripts in both modes and compares the output, the error, `errorInfo`, the steps, and the memory count. |
| `tools/jit-diff.sh` | Each script of `tests/jit/`, `tests/mem/`, and `bench/` in three modes (no JIT, `--jit --jit-threshold 0`, `--jit`) with `--gc off`: the output, the exit code, the steps, and the memory count. The interpreter output of `tests/jit/` equals the `.out` file from tclsh. Then the step limit sweep of `tests/jit/sweep/`, and the native stack of 500 proc calls with the suite runner. `-x "--gc-stress 1"` adds the stress mode. |
| `tools/suite.sh -j` | The suite with `--jit --jit-threshold 0`. Each file has the pass count of the run without `-j`. |
| `tools/jit-perf.sh --check off` and `--check jit` | The instruction counts of `puts hi` and `bench/` against `bench/jit-baseline.tsv` (at most 1 % above) and `bench/jit-gates.tsv`. |
| `tools/jit-asm-golden.sh --check` | The golden table of the assembler is the output of `zig cc` today. |
| `tools/gc-fuzz.py -r <runner> -j` | The collector fuzzer with the JIT at threshold 0 in the stress run. |
| `tools/kostya.sh --jit` | The outside programs with the JIT. |

## Benchmarks

```sh
zig build bench                                 # the point procs
python3 -I tools/bench.py --tclsh <path to tclsh>  # the scripts in bench/
```

`--tclsh` selects the Tcl version. [Tcl 8.6 and Tcl 9](tcl9.md) has the results for both versions and the suite totals of Tcl 9.1.0.

Measured on an Intel Core i7-6700K (4.0 GHz, AVX2), one thread, `ReleaseFast`, 2026-11-23. Each time is the best of 11 runs of the whole process, in CPU milliseconds (user and system). The machine had other load, and CPU time stays stable under that load.

| Benchmark (`bench/`) | ztcl | tclsh 8.6.16 | tclsh 9.1.0 |
|---|---|---|---|
| `sum.tcl` (1 million `expr` and `incr`) | 20.2 | 58.3 | 57.8 |
| `fib.tcl` (fib 25, about 250 000 calls) | 14.4 | 50.8 | 49.4 |
| `nested.tcl` (1000 x 1000, `lappend`, `llength`) | 31.8 | 73.7 | 84.7 |
| `strbuild.tcl` (500 000 `append`) | 23.0 | 63.8 | 99.2 |
| `foreach.tcl` (10 passes over 100 000 items) | 16.2 | 33.2 | 38.6 |
| `dict.tcl` (200 000 `dict incr`, 200 000 `dict get`) | 22.8 | 48.6 | 58.5 |
| `dictgrow.tcl` (200 000 new keys, 200 000 `dict get`) | 61.4 | 104.9 | 144.2 |
| `readloop.tcl` (200 000 `llength` and `lindex` on a string) | 17.7 | 27.9 | 32.7 |

The table above is from the commit before the work on the 152 test files. A store to a cell that already has a value now writes only the payload, and a traced or linked cell goes to a cold path.

The work on the event loop, `socket`, `exec`, and TclOO changed the instruction counts of these eight scripts by less than 0.01 % (`perf stat -e instructions:u`, against the commit before that work). The times of the table stay valid.

The fuzzy skin proc (`zig build bench`), measured again on 2026-11-23 with other load on the machine:

| Points | Fast path | Slow path |
|---|---|---|
| 1 million, a third on the outer wall | 15.0 ns for each point | about 137 ns for each point |
| 1 million, all on the outer wall | 14.9 ns for each point | about 232 ns for each point |
| 10 million, all on the outer wall | 15.1 ns for each point (0.15 s) | about 231 ns for each point (2.3 s) |

The slow path uses the bytecode. The points of this benchmark are 0.04 mm apart. At a spacing of 0.5 mm the fast path uses about 15.9 ns for each point.
