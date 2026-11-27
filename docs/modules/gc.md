# Module ztcl::gc

`ztcl::gc` gives the counts of the collector of the heap of an interpreter tree: the pauses, the time of the marks and the sweeps, the bytes of the heap, the bytes that the program allocated, and the resident set of the process. It is the dashboard of the work on the collector (ztcl#526), and of a host that reads the memory of its scripts.

```tcl
ztcl::gc reset
run_the_work
set s [ztcl::gc stats]
puts "[dict get $s collections] collections, p99 pause [expr {[dict get $s pause_p99_ns] / 1000}] us"
puts "peak heap [dict get $s heap_peak] bytes, resident set [dict get $s rss] bytes"
```

The command is not a package: it exists when the embedder turns on the capability `meter`, as `ztcl::meter` does, and it is absent otherwise. The counts of time and of the resident set depend on the host, so the capability is off by default, as the clock is.

## Commands

```tcl
ztcl::gc stats
ztcl::gc collect
ztcl::gc reset
```

- `stats` gives a dict of the counts below.
- `collect` runs a collection now, at the safe point of the command. A build that cannot collect at that point, such as WebAssembly in a native frame, runs none.
- `reset` starts the counts again: the collections, the times, the pauses, the bytes allocated and freed, and the peak of the heap.

| Key | What it counts |
|---|---|
| `collections` | The collections since the start of the counts. |
| `gc_ns`, `mark_ns`, `sweep_ns` | The time of the collections, of their marks, and of their sweeps, in ns. |
| `pause_p50_ns`, `pause_p99_ns`, `pause_max_ns` | The median, the 99th percentile, and the longest pause, in ns. The percentiles come from the last 1,024 collections. |
| `heap_bytes`, `heap_peak` | The bytes of the pages of the heap now, and their peak. |
| `live_bytes` | The bytes of the blocks that the last collection kept. |
| `used_bytes` | The bytes of the blocks in use now, live or not. |
| `threshold` | The bytes of the heap at which the next collection starts. |
| `allocated`, `freed` | The bytes that the program allocated, and the bytes that the collections freed. |
| `alloc_rate` | The allocated bytes a second since the start of the counts. |
| `uptime_ns` | The time since the start of the counts. |
| `rss`, `rss_peak` | The resident set of the process and its peak, from the system: the working set on Windows, `VmRSS` and `VmHWM` on Linux, and the resident size of `task_info` on macOS. 0 on a target with no count. |

The times come from a clock that does not go back. The collector reads it only at the start of a collection, at the end of its mark, and at the end of its sweep, so an allocation costs no more. The count of allocated bytes comes from the collections too: the blocks in use before a sweep, less the live bytes after the last one.

The heap counts only its own pages. The resident set also has the memory that the heap gave back and the system still holds, the memory of the rest of the process, and the code.

## The benchmarks

`bench/gc/` has a set of scripts for the collector, and `bench/gc/run.tcl` runs each one in a process of its own and prints a table of its counts. [The benchmarks](../../bench/gc/README.md) tells what each one measures.
