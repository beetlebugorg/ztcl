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
tools/suite.sh                        # core-8-6-16
tools/suite.sh -t <tag>               # another Tcl release
tools/suite.sh -s <tcl source>/tests  # a local folder
tools/suite.sh set.test expr.test     # some files
```

`tools/tcltest.tcl` is a small stand-in for the `tcltest` package. A test with an unknown constraint, a regexp match, or an `-output` check counts as skipped.

### Results with Tcl 8.6.16 (`core-8-6-16`)

| File | Pass | Fail | Skip |
|---|---|---|---|
| `set.test` | 61 | 2 | 1 |
| `incr.test` | 62 | 4 | 0 |
| `if.test` | 72 | 1 | 0 |
| `while.test` | 45 | 1 | 0 |
| `for.test` | 60 | 4 | 24 |
| `foreach.test` | 38 | 5 | 0 |
| `proc.test` | 20 | 17 | 1 |
| `uplevel.test` | 40 | 17 | 0 |
| `upvar.test` | 34 | 23 | 8 |
| `expr.test` | 14080 | 56 | 49 |
| `list.test` | 77 | 1 | 0 |
| `lindex.test` | 37 | 9 | 37 |
| `llength.test` | 5 | 1 | 0 |
| `lrange.test` | 30 | 2 | 2 |
| `linsert.test` | 27 | 1 | 0 |
| `lreplace.test` | 1787 | 0 | 0 |
| `lsearch.test` | 109 | 9 | 0 |
| `join.test` | 7 | 3 | 0 |
| `split.test` | 14 | 3 | 0 |
| `concat.test` | 9 | 0 | 0 |
| `append.test` | 28 | 17 | 0 |
| `string.test` | 455 | 169 | 10 |
| `format.test` | 224 | 32 | 10 |
| `switch.test` | 93 | 20 | 0 |
| `eval.test` | 11 | 1 | 0 |
| `parse.test` | 65 | 25 | 181 |
| `lmap.test` | 55 | 11 | 0 |
| `apply.test` | 22 | 16 | 4 |
| `rename.test` | 8 | 3 | 8 |
| `error.test` | 283 | 19 | 15 |
| `lset.test` | 0 | 0 | 89 |
| `namespace.test` | 161 | 149 | 3 |
| `regexp.test` | 207 | 32 | 5 |
| `binary.test` | 565 | 72 | 80 |
| `info.test` | 61 | 188 | 14 |
| `dict.test` | 291 | 49 | 2 |
| `scan.test` | 145 | 35 | 1 |
| **Total** | **19288** | **997** | **544** |

The largest groups of tests that still fail: `info frame` (about 120), `trace` (about 45), `tcl::prefix` (37), `upvar` to an array element, the error codes of the core commands (`ARITH DIVZERO`), `-during` in the options of `try`, and the details of `namespace`.

## Benchmarks

```sh
zig build bench                                 # the point procs
python3 -I tools/bench.py --tclsh <path to tclsh>  # the scripts in bench/
```

`--tclsh` selects the Tcl version. [Tcl 8.6 and Tcl 9](tcl9.md) has the results for both versions and the suite totals of Tcl 9.1.0.

Measured on an Intel Core i7-6700K (4.0 GHz, AVX2), one thread, `ReleaseFast`, 2026-11-22. Each time is the best of 9 runs of the whole process, in CPU milliseconds (user and system). The machine had other load, and CPU time stays stable under that load.

| Benchmark (`bench/`) | ztcl | tclsh 8.6.16 | tclsh 9.1.0 |
|---|---|---|---|
| `sum.tcl` (1 million `expr` and `incr`) | 24.8 | 58.4 | 57.9 |
| `fib.tcl` (fib 25, about 250 000 calls) | 16.7 | 51.0 | 49.2 |
| `nested.tcl` (1000 x 1000, `lappend`, `llength`) | 36.4 | 73.5 | 84.8 |
| `strbuild.tcl` (500 000 `append`) | 35.2 | 63.7 | 98.7 |
| `foreach.tcl` (10 passes over 100 000 items) | 19.6 | 33.4 | 38.5 |
| `dict.tcl` (200 000 `dict incr`, 200 000 `dict get`) | 30.5 | 48.7 | 58.4 |
| `dictgrow.tcl` (200 000 new keys, 200 000 `dict get`) | 84.5 | 104.2 | 143.3 |

The fuzzy skin proc (`zig build bench`):

| Points | Fast path | Slow path |
|---|---|---|
| 1 million, a third on the outer wall | 23 ns for each point | about 160 ns for each point |
| 1 million, all on the outer wall | 23 ns for each point | about 250 ns for each point |
| 10 million, all on the outer wall | 23 ns for each point (0.23 s) | about 250 ns for each point (2.5 s) |

The slow path uses the bytecode.
