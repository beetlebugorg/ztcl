# Performance

The sections "The interpreter", "A 10-million-pass integer loop", "Threads", "JSON", and "Size" come from a GitHub `ubuntu-latest` runner (4 vCPU, AMD EPYC), the median of 3 runs of the workflow `bench.yml` with `site` set, on 2026-11-27. The three runs had three CPU models: AMD EPYC 9V45, 9V74, and 7763. Each build is `ReleaseFast` for the CPU of the runner, and `tclsh` 8.6.16 with Thread 2.8.11 is a build of the source release. The runner has no hardware counter for `perf`, so the instruction counts and the larger programs come from an Intel Core i7-6700K (4 cores, 8 hardware threads, 4.0 GHz, AVX2) on x86-64 Linux, on the date of each section. The scripts are in [`bench/`](../bench). Run them yourself:

```sh
zig build -Doptimize=ReleaseFast
python3 -I tools/bench-site.py --tclsh "$(command -v tclsh)"
gh workflow run bench.yml -f site=true
```

## The interpreter

CPU milliseconds of the whole process, best of 11 runs, one thread. `--no-jit` is the bytecode interpreter, and the default has the JIT. Lower is faster.

| Benchmark | ztcl `--no-jit` | ztcl | tclsh 8.6.16 |
|---|---|---|---|
| `sum.tcl`: 1 million `expr` and `incr` | 16.4 | 1.5 | 43.8 |
| `fib.tcl`: fib 25, about 250,000 calls | 17.1 | 8.9 | 38.6 |
| `nested.tcl`: 1000 x 1000, `lappend`, `llength` | 29.4 | 14.4 | 56.2 |
| `strbuild.tcl`: 500,000 `append` | 19.4 | 15.7 | 50.3 |
| `foreach.tcl`: 10 passes over 100,000 items | 14.8 | 5.6 | 25.5 |
| `dict.tcl`: 200,000 `dict incr`, 200,000 `dict get` | 22.2 | 14.4 | 36.4 |
| `dictgrow.tcl`: 200,000 new keys, 200,000 `dict get` | 75.1 | 70.9 | 90.7 |
| `readloop.tcl`: 200,000 `llength` and `lindex` on a string | 11.8 | 9.4 | 20.2 |
| `dsum.tcl`: 1 million `expr` on doubles | 48.1 | 1.7 | 71.4 |

The table of 2026-11-23 on the Intel Core i7-6700K also had `tclsh` 9.1.0: 57.8, 49.4, 84.7, 99.2, 38.6, 58.5, 144.2, and 32.7 ms for the first eight rows. The runner has no build of it.

### A 10-million-pass integer loop

`sum` of `bench/sum.tcl` with 10,000,000 passes. Wall milliseconds of the call from `clock microseconds`, best of 5 runs.

| Runner | ms |
|---|---|
| ztcl `--no-jit` | 156.6 |
| ztcl `--no-jit-tier2` | 67.4 |
| ztcl (the default, JIT tier 2) | 8.3 |
| tclsh 8.6.16 | 413.4 |

## The JIT

User CPU instructions of the whole process, in millions, from `perf stat -e instructions:u`, 2026-11-24. Instruction counts do not change with the load of the machine.

| Script | `--no-jit` | `--no-jit-tier2` | default | tclsh 8.6.16 |
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

| Program | `--no-jit` | `--no-jit-tier2` | default | tclsh 8.6.16 |
|---|---|---|---|---|
| `bf.tcl small.b` | 0.84 | 0.65 | 0.65 | 2.73 |
| `bf_oo.tcl small.b` | 4.22 | 3.40 | 3.70 | 8.17 |
| `base64/test.tcl` | 4.88 | 5.78 | 5.81 | 5.84 |

## Threads

Wall milliseconds that each script prints, best of 5 runs, against `tclsh` 8.6.16 with Thread 2.8.11. The runner has 4 vCPU, and the scripts use 4 to 8 threads.

```sh
ztcl --allow thread,event,package,clock bench/thread_pipe.tcl
tclsh bench/thread_pipe.tcl
```

| Benchmark | ztcl | tclsh 8.6.16 |
|---|---|---|
| `thread_map.tcl`: 1,000,000 integers in 8 parts, a proc on each | 120 | 264 |
| `thread_pipe.tcl`: 4 stages, 100,000 messages | 479 | 439 |
| `thread_tsv.tcl`: 8 threads, 100,000 `tsv::incr` each, one element | 268 | 1,481 |
| `thread_tsv.tcl`: the same, 8 elements | 422 | 1,803 |
| `thread_tpool.tcl`: 8 workers, 100,000 jobs | 639 | 556 |

## JSON

MB/s of the input text, best of 5 runs, from `tools/bench-stdlib.py` on the three standard files of the simdjson benchmarks. Each program times its own work, so the process start and the file read are not in the number. Higher is faster. The C libraries simdjson and yyjson are in the TSV file of the workflow.

`parse` makes the native value of each runtime: a Tcl dict, a JS object, a Python dict, or a Go `interface{}`.

| Runtime | twitter | canada | citm_catalog |
|---|---:|---:|---:|
| **ztcl `ztcl::json parse`** | **1,180** | 379 | **1,348** |
| Python `orjson` | 820 | **523** | 751 |
| Node.js `JSON.parse` | 595 | 201 | 629 |
| Python `pysimdjson` | 493 | 442 | 587 |
| Python `json` | 319 | 67 | 293 |
| Go `encoding/json` | 125 | 87 | 132 |
| tclsh with tcllib `json` | 3.8 | 2.2 | 4.8 |

`query` reads one value at a path. `ztcl::json get` walks the structural index and makes only the value at the end.

| Runtime | twitter | canada | citm_catalog |
|---|---:|---:|---:|
| **ztcl `ztcl::json get`** | **2,200** | **798** | **2,489** |
| Python `orjson` | 821 | 521 | 626 |
| Node.js | 601 | 200 | 628 |
| Python `pysimdjson` | 484 | 439 | 506 |
| Python `json` | 317 | 67 | 313 |
| Go `encoding/json` | 127 | 86 | 129 |

## Point procs

A `point proc` compiles one body to a vector program over blocks of 1024 points. The fuzzy skin proc of `zig build bench`, over 10 million points, 2026-11-23:

| Path | Time for each point |
|---|---|
| Vector path | 15.1 ns |
| Bytecode | about 231 ns |

The two paths give the same results, bit for bit.

## Size

ztcl is one static binary and links no library. A CI gate (`tools/size-report.sh --check`) keeps the stripped x86-64 Linux runner with all modules under 6 MB, and `ztcl.wasm` with its modules under 1.5 MB. On the runner, the stripped `ReleaseFast` runner is 5,180,328 bytes (2,143,942 with gzip -9), and `ztcl hi.tcl` with one `puts` starts in 0.63 ms, the median of 50 runs (`tclsh` 8.6.16: 2.17 ms). `ztcl.wasm` is 1,488,640 bytes, and 507,742 with gzip -9.
