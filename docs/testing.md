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
tools/suite.sh -a -o run.tsv          # all files, with a log for the table
python3 -I tools/suite-table.py run.tsv > docs/compatibility.md
tools/suite.sh -t <tag>               # another Tcl release
tools/suite.sh -s <tcl source>/tests  # a local folder
tools/suite.sh set.test expr.test     # some files
```

`tools/tcltest.tcl` is a small stand-in for the `tcltest` package. It evaluates the constraints in the three forms of `tcltest`, and it checks `-output`, `-errorOutput`, and the `exact`, `glob`, `regexp`, and custom match modes. A failed cleanup is a failure. A test with a false constraint counts as skipped, and the log records the constraint. `tools/tcltest-end.tcl` prints the counts after each file.

`tools/suite-count.tcl` counts the tests of a file with a real `tclsh`, in a safe interpreter. `tools/suite-scope.tsv` has the count and the scope of each file.

[Compatibility](compatibility.md) has the table for all 152 files. A test that did not run counts as blocked. It does not count as a pass.

### Results with Tcl 8.6.16 (`core-8-6-16`), the 37 core files

The stand-in changed, so the totals before this work are 19 290 pass, 1 013 fail, and 526 skip with the same stand-in.

| File | Pass | Fail | Skip |
|---|---|---|---|
| `set.test` | 61 | 2 | 1 |
| `incr.test` | 62 | 4 | 0 |
| `if.test` | 73 | 0 | 0 |
| `while.test` | 45 | 1 | 0 |
| `for.test` | 60 | 4 | 24 |
| `foreach.test` | 41 | 2 | 0 |
| `proc.test` | 25 | 12 | 1 |
| `uplevel.test` | 49 | 8 | 0 |
| `upvar.test` | 42 | 15 | 8 |
| `expr.test` | 14121 | 15 | 49 |
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
| `string.test` | 618 | 6 | 10 |
| `format.test` | 225 | 32 | 9 |
| `switch.test` | 105 | 8 | 0 |
| `eval.test` | 11 | 1 | 0 |
| `parse.test` | 84 | 6 | 181 |
| `lmap.test` | 60 | 6 | 0 |
| `apply.test` | 33 | 5 | 4 |
| `rename.test` | 10 | 1 | 8 |
| `error.test` | 300 | 9 | 8 |
| `lset.test` | 0 | 0 | 89 |
| `namespace.test` | 230 | 80 | 3 |
| `regexp.test` | 208 | 31 | 5 |
| `binary.test` | 602 | 36 | 79 |
| `info.test` | 97 | 161 | 5 |
| `dict.test` | 311 | 29 | 2 |
| `scan.test` | 145 | 35 | 1 |
| **Total** | **19780** | **523** | **526** |

The largest groups of tests that still fail in scope: TclOO (`oo`, `ooNext2`), `info frame`, step traces, `coroutine`, `tailcall`, the bytecode tools (`tcl::unsupported::disassemble`), the `%n$` forms of `format` and `scan`, and the longest-match rules of regular expressions.

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

The fuzzy skin proc (`zig build bench`):

| Points | Fast path | Slow path |
|---|---|---|
| 1 million, a third on the outer wall | 14.9 ns for each point | about 139 ns for each point |
| 1 million, all on the outer wall | 14.8 ns for each point | about 225 ns for each point |
| 10 million, all on the outer wall | 14.8 ns for each point (0.15 s) | about 219 ns for each point (2.2 s) |

The slow path uses the bytecode. The points of this benchmark are 0.04 mm apart. At a spacing of 0.5 mm the fast path uses about 15.9 ns for each point.
