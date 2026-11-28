# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::gc {
    area ztcl
    since TODO
    synopsis {ztcl::gc subcommand}
    summary {Gives the counts of the collector of the heap of the interpreter tree: the pauses, the time of the marks and the sweeps, the bytes of the heap, the bytes that the program allocated, and the resident set of the process.}
    description {Gives the counts of the collector of the heap of the interpreter tree: the pauses, the time of the marks and the sweeps, the bytes of the heap, the bytes that the program allocated, and the resident set of the process. The counts of time depend on the host.}
    capability {meter}
    page {modules/gc.md}
    flags {--allow meter}
    example {ztcl::gc reset} TODO
    example {dict get [ztcl::gc stats] collections} 0
    example {dict size [ztcl::gc stats]} 20
    error {ztcl::gc nope} {bad option "nope": must be collect, reset, or stats} NONE
    subcommand stats {
        synopsis {ztcl::gc stats}
        summary {A dict of the counts: `collections`, `gc_ns`, `mark_ns`, `sweep_ns`, `pause_p50_ns`, `pause_p99_ns`, `pause_max_ns`, `heap_bytes`, `heap_peak`, `live_bytes`, `used_bytes`, `threshold`, `allocated`, `freed`, `alloc_rate`, `uptime_ns`, `rss`, `rss_peak`, `returned`, and `retained`.}
        description {A dict of the counts: `collections`, `gc_ns`, `mark_ns`, `sweep_ns`, `pause_p50_ns`, `pause_p99_ns`, `pause_max_ns`, `heap_bytes`, `heap_peak`, `live_bytes`, `used_bytes`, `threshold`, `allocated`, `freed`, `alloc_rate`, `uptime_ns`, `rss`, `rss_peak`, `returned`, and `retained`.}
    }
    subcommand collect {
        synopsis {ztcl::gc collect}
        summary {Runs a collection now, where the build can collect.}
        description {Runs a collection now, where the build can collect.}
    }
    subcommand reset {
        synopsis {ztcl::gc reset}
        summary {Starts the counts again.}
        description {Starts the counts again.}
    }
}
