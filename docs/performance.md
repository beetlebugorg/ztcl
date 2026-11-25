# Performance

All numbers on this page come from one machine: an Intel Core i7-6700K (4 cores, 8 hardware threads, 4.0 GHz, AVX2) on x86-64 Linux, with `ReleaseFast` builds. Each section gives its method and its date. The scripts are in [`bench/`](../bench). Run them yourself:

```sh
zig build -Doptimize=ReleaseFast
python3 -I tools/bench.py --tclsh "$(command -v tclsh)"
```

## The interpreter

CPU milliseconds of the whole process, best of 11 runs, one thread, 2026-11-23. Lower is faster.

| Benchmark | ztcl | tclsh 8.6.16 | tclsh 9.1.0 |
|---|---|---|---|
| `sum.tcl`: 1 million `expr` and `incr` | 20.2 | 58.3 | 57.8 |
| `fib.tcl`: fib 25, about 250,000 calls | 14.4 | 50.8 | 49.4 |
| `nested.tcl`: 1000 x 1000, `lappend`, `llength` | 31.8 | 73.7 | 84.7 |
| `strbuild.tcl`: 500,000 `append` | 23.0 | 63.8 | 99.2 |
| `foreach.tcl`: 10 passes over 100,000 items | 16.2 | 33.2 | 38.6 |
| `dict.tcl`: 200,000 `dict incr`, 200,000 `dict get` | 22.8 | 48.6 | 58.5 |
| `dictgrow.tcl`: 200,000 new keys, 200,000 `dict get` | 61.4 | 104.9 | 144.2 |
| `readloop.tcl`: 200,000 `llength` and `lindex` on a string | 17.7 | 27.9 | 32.7 |

The two `tclsh` builds can differ in compiler flags.

## The JIT

User CPU instructions of the whole process, in millions, from `perf stat -e instructions:u`, 2026-11-24. Instruction counts do not change with the load of the machine.

| Script | Interpreter | `--jit` | `--jit --jit-tier2` | tclsh 8.6.16 |
|---|---|---|---|---|
| `sum.tcl` | 283.8 | 90.9 | 15.0 | 684.3 |
| `dsum.tcl` | 688.8 | 555.9 | 16.6 | 1212.5 |
| `nested.tcl` | 333.4 | 123.5 | 55.3 | 934.0 |
| `foreach.tcl` | 206.9 | 80.4 | 40.6 | 387.1 |
| `dict.tcl` | 280.7 | 194.9 | 188.6 | 555.3 |
| `dictgrow.tcl` | 647.7 | 590.3 | 588.3 | 825.5 |
| `readloop.tcl` | 145.3 | 93.3 | 85.3 | 302.3 |
| `strbuild.tcl` | 322.9 | 252.5 | 243.1 | 812.4 |
| `fib.tcl` | 151.0 | 106.0 | 106.0 | 600.9 |

### Larger programs

Three programs of [kostya/benchmarks](https://github.com/kostya/benchmarks): the brainfuck interpreter `bf.tcl`, its TclOO form `bf_oo.tcl`, and `base64`. Each output of ztcl equals the output of `tclsh`. Wall time in seconds, best of 5 runs, each run pinned to one core with `taskset`. `bf` uses `small.b`, a shorter form of `bench.b`. Other jobs shared the machine, so these times are rough.

| Program | Interpreter | `--jit` | `--jit --jit-tier2` | tclsh 8.6.16 |
|---|---|---|---|---|
| `bf.tcl small.b` | 0.84 | 0.65 | 0.65 | 2.73 |
| `bf_oo.tcl small.b` | 4.22 | 3.40 | 3.70 | 8.17 |
| `base64/test.tcl` | 4.88 | 5.78 | 5.81 | 5.84 |

## Threads

Wall milliseconds, best of 5 runs, against `tclsh` 8.6.16 with Thread 2.8.11, 2026-11-24. Each script prints its own time, and the runs of ztcl and `tclsh` alternated. The machine had other load, so the times vary between runs.

```sh
ztcl --allow thread,event,package,clock bench/thread_pipe.tcl
tclsh bench/thread_pipe.tcl
```

| Benchmark | ztcl | tclsh 8.6.16 |
|---|---|---|
| `thread_map.tcl`: 1,000,000 integers in 8 parts, a proc on each | 99 | 305 |
| `thread_pipe.tcl`: 4 stages, 100,000 messages | 605 | 706 |
| `thread_tsv.tcl`: 8 threads, 100,000 `tsv::incr` each, one element | 1249 | 2458 |
| `thread_tsv.tcl`: the same, 8 elements | 1214 | 3276 |
| `thread_tpool.tcl`: 8 workers, 100,000 jobs | 466 | 639 |

## JSON

MB/s of the input text, best of 5 runs, from `tools/bench-stdlib.py --only json` on the three standard files of the simdjson benchmarks. Each program times its own work, so the process start and the file read are not in the number. Other builds ran on the machine during the run. Higher is faster.

`parse` makes the native value of each runtime: a Tcl dict, a JS object, a Python dict, or a Go `interface{}`.

| Runtime | twitter | canada | citm_catalog |
|---|---:|---:|---:|
| **ztcl `zt::json parse`** | **794** | 228 | **952** |
| Node.js `JSON.parse` | 354 | 259 | 494 |
| Python `orjson` | 499 | 206 | 385 |
| Python `pysimdjson` | 263 | 224 | 302 |
| Python `json` | 176 | 63 | 207 |
| Go `encoding/json` | 115 | 72 | 129 |
| tclsh with tcllib `json` | 2.9 | 1.5 | 3.5 |

`query` reads one value at a path. `zt::json get` walks the structural index and makes only the value at the end.

| Runtime | twitter | canada | citm_catalog |
|---|---:|---:|---:|
| **ztcl `zt::json get`** | **1308** | **615** | **1664** |
| Python `orjson` | 491 | 245 | 376 |
| Node.js | 355 | 259 | 493 |
| Python `pysimdjson` | 295 | 216 | 274 |
| Python `json` | 176 | 64 | 211 |
| Go `encoding/json` | 114 | 74 | 128 |

The C and C++ libraries are faster on most files: simdjson on each file, and yyjson on twitter and canada. [PR #55](https://github.com/beetlebugorg/ztcl/pull/55) has the full table with them.

## Point procs

A `point proc` compiles one body to a vector program over blocks of 1024 points. The fuzzy skin proc of `zig build bench`, over 10 million points, 2026-11-23:

| Path | Time for each point |
|---|---|
| Vector path | 15.1 ns |
| Bytecode | about 231 ns |

The two paths give the same results, bit for bit.

## Size

ztcl is one static binary and links no library. A CI gate (`tools/size-report.sh --check`) keeps the stripped x86-64 Linux runner with all modules under 6 MB, and `ztcl.wasm` with its modules under 1.5 MB.
