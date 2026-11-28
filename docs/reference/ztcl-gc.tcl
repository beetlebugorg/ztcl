# The command reference: ztcl::gc. The format is in
# docs/dev/reference-format.md.

command ztcl::gc {
    area ztcl
    since 1.0.0-beta.1
    capability meter
    flags {--allow meter}
    synopsis {ztcl::gc SUBCOMMAND}
    summary {Gives the counts of the collector of the heap of the interpreter tree.}
    description {
        The counts of the collector of the heap of an interpreter tree: the pauses, the time of the marks and the sweeps, the bytes of the heap, the bytes that the program allocated, and the resident set of the process. It serves the work on the collector and a host that reads the memory of its scripts.

        The command is not a package: it exists when the embedder turns on the capability `meter`, as `ztcl::meter` does, and it is absent otherwise. The counts of time and of the resident set depend on the host, so the capability is off by default, as the clock is. The examples of this page run with `--allow meter`.

        A unique prefix of a subcommand names the subcommand. An unknown or ambiguous subcommand gives `-errorcode` `TCL LOOKUP SUBCOMMAND` with the word at the end.
    }
    returns {The result of the subcommand.}
    page modules/gc/
    see {ztcl::meter {interp limits}}
    example {
        ztcl::gc reset
        dict get [ztcl::gc stats] collections
    } 0
    example {dict size [ztcl::gc stats]} 20
    example {dict exists [ztcl::gc s] collections} 1
    error {ztcl::gc nope} {unknown or ambiguous subcommand "nope": must be collect, reset, or stats} {TCL LOOKUP SUBCOMMAND nope}
    error {ztcl::gc} {wrong # args: should be "ztcl::gc stats|collect|reset"} {TCL WRONGARGS}

    subcommand stats {
        synopsis {ztcl::gc stats}
        summary {Gives a dict of the counts of the collector.}
        description {
            Gives a dict with these keys, each an integer:

            - `collections`: the collections since the start of the counts;
            - `gc_ns`, `mark_ns`, `sweep_ns`: the time of the collections, of their marks, and of their sweeps, in ns;
            - `pause_p50_ns`, `pause_p99_ns`, `pause_max_ns`: the median, the 99th percentile, and the longest pause, in ns, the percentiles of the last 1,024 collections;
            - `heap_bytes`, `heap_peak`: the bytes of the pages of the heap now, and their peak;
            - `live_bytes`: the bytes of the blocks that the last collection kept;
            - `used_bytes`: the bytes of the blocks in use now, live or not;
            - `threshold`: the bytes of the heap at which the next collection starts;
            - `allocated`, `freed`: the bytes that the program allocated, and the bytes that the collections freed;
            - `alloc_rate`: the allocated bytes a second since the start of the counts;
            - `uptime_ns`: the time since the start of the counts;
            - `rss`, `rss_peak`: the resident set of the process and its peak, from the system: the working set on Windows, `VmRSS` and `VmHWM` on Linux, and the resident size of `task_info` on macOS, or 0 on a target with no count;
            - `returned`, `retained`: the bytes of free pages that the heap gave back to the system, and the bytes of free pages that it keeps for its next spans, at least 4 MiB; 0 on WebAssembly, where the heap has no page pool.

            The times come from a clock that does not go back, read only at the start of a collection, at the end of its mark, and at the end of its sweep, so an allocation costs no more. The count of allocated bytes comes from the collections too. The heap counts only its own pages, and the resident set also has the memory of the rest of the process.
        }
        returns {A dict of 20 integers.}
        see {{ztcl::gc reset}}
        example {dict keys [ztcl::gc stats]} {collections gc_ns mark_ns sweep_ns pause_p50_ns pause_p99_ns pause_max_ns heap_bytes heap_peak live_bytes used_bytes threshold allocated freed alloc_rate uptime_ns rss rss_peak returned retained}
        example {
            set ok 1
            dict for {k v} [ztcl::gc stats] { if {![string is wide -strict $v]} { set ok 0 } }
            set ok
        } 1
        error {ztcl::gc stats x} {wrong # args: should be "ztcl::gc stats|collect|reset"} {TCL WRONGARGS}
    }

    subcommand collect {
        synopsis {ztcl::gc collect}
        summary {Runs a collection now.}
        description {Runs a collection at the safe point of the command. A build that cannot collect at that point, such as WebAssembly in a native frame, runs none.}
        returns {An empty string.}
        see {{ztcl::gc stats}}
        example {
            ztcl::gc reset
            ztcl::gc collect
            dict get [ztcl::gc stats] collections
        } 1
        error {ztcl::gc collect x} {wrong # args: should be "ztcl::gc stats|collect|reset"} {TCL WRONGARGS}
    }

    subcommand reset {
        synopsis {ztcl::gc reset}
        summary {Starts the counts again.}
        description {Sets the counts of the collections, the times, the pauses, the bytes allocated and freed, and the peak of the heap to their start.}
        returns {An empty string.}
        see {{ztcl::gc stats}}
        example {
            ztcl::gc collect
            ztcl::gc reset
            dict get [ztcl::gc stats] collections
        } 0
        error {ztcl::gc reset x} {wrong # args: should be "ztcl::gc stats|collect|reset"} {TCL WRONGARGS}
    }
}
