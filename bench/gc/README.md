# The benchmarks of the collector

The scripts of this folder measure the collector of ztcl (ztcl#526) with the counts of [`ztcl::gc stats`](../../docs/modules/gc.md). `run.tcl` runs each script in a process of its own with fresh counts, and prints a table with the median of each count:

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/ztcl --allow exec,file,clock,channels --tclsh bench/gc/run.tcl zig-out/bin/ztcl -runs 3
```

A list of scripts after the program measures those scripts, such as the scripts of `bench/`.

| Script | What it measures |
|---|---|
| `strings.tcl` | Short strings at a high rate with little live data: the allocation and the sweep of young garbage. |
| `lists.tcl` | Lists of 1,000 strings, built and dropped: blocks of middle sizes and the buffers of growing lists. |
| `dicts.tcl` | Dicts of 500 keys, filled and replaced: the hash tables and their entries. |
| `live.tcl` | A live set of 300,000 strings while young garbage goes by: the pause of a mark of a large heap. |
| `peak.tcl` | A peak of about 200 MB, then a small live set: the memory that the process holds after a peak. |
| `recurse.tcl` | Deep recursion with temporary values in each frame: the scan of the stacks and the frames. |

The columns: the wall time of the script, the collections and their time, the median, the 99th percentile, and the longest pause, the peak and the end of the heap, the end and the peak of the resident set, and the allocation rate.
