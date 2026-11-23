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
