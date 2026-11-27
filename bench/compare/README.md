# Comparison benchmarks

The same tasks in ztcl, Tcl 8.6 (`tclsh`), Python 3, Go, and Zig. Each program is the code that a fluent user of the language writes with its standard library. The real-world tasks come first. `fib` and `nbody` are micro benchmarks, and the charts label them so.

## Run

Build ztcl first, then run the suite from the root of the repository:

```sh
zig build -Doptimize=ReleaseFast
python3 -I bench/compare/run.py --check    # small inputs: the outputs must agree
python3 -I bench/compare/run.py            # the full run, 15 minutes or more
python3 -I bench/compare/chart.py          # docs/site/bench/*.svg from results.tsv
```

The runner needs `tclsh` 8.6, Python 3.11 or later, Go, and Zig 0.17.0 (`--zig PATH`). `--tcllib DIR` gives the modules folder of tcllib for the `json` task of `tclsh`, because the core of Tcl has no JSON parser. With no tcllib, the charts show n/a there. `--only json,csv` runs some tasks, and `--langs ztcl,go` runs some languages.

## How it measures

- Each time is the wall clock of the whole process in milliseconds, from the start of the process to its exit. It includes the start of the runtime and the read of the input file. The `hello` task shows the start alone.
- The `http` task gives requests for each second: `load/load.zig` sends GET requests one after the other on one keep-alive connection for 3 seconds. Each server uses one thread (`GOMAXPROCS=1` for Go).
- The `tls` task opens 20 connections to a Go TLS 1.3 server (`go/tlsserver.go`, X25519, ECDSA P-256). Each client checks the certificate, reads 1 MiB, and closes.
- A round runs each task once in each language, in a new random order. After 5 rounds, the runner goes on until the interquartile range of each value is at most 5 % of its median, or to 15 rounds. Each run has `nice -n 10`.
- In the first round, the runner compares the output of each language for each task, byte for byte, and stops on a difference.
- `results.tsv` has the median, the quartiles, the extremes, and the count of runs of each value, and the CPU, the OS, the versions, and the load average.

## The tasks

| Task | Input | Work |
|---|---|---|
| `base64` | 16 MiB of random bytes | encode to base64, decode, compare |
| `json` | 25 MB of records | parse to native values, write again with no spaces |
| `csv` | 1,000,000 rows of sales, some fields in quotes | sum the quantity and the revenue for each region and product |
| `weblog` | 200,000 lines of a web server log (22 MB) | match each line with a regular expression, count by status and path |
| `wordfreq` | 20 MB of text | lower case, split into words, the 20 most frequent words |
| `strfmt` | none | build one string of 1,000,000 lines from a format |
| `template` | none | render an HTML table of 100,000 rows, with HTML escapes |
| `sort_int`, `sort_str` | 1,000,000 integers or strings | read, parse, and sort |
| `http` | none | an HTTP/1.1 server with a small JSON body |
| `tls` | none | 20 TLS 1.3 handshakes and 1 MiB on each |
| `hello` | none | print one line and exit |
| `fib` (micro) | none | recursive `fib 30` |
| `nbody` (micro) | none | the n-body simulation of the Benchmarks Game, 50,000 steps |

## The programs

- `tcl/`: one script for `tclsh` and ztcl. `ztcl/` has the scripts that use a command of ztcl: `ztcl::json` and `ztcl::tls`. `csv.tcl` splits each line with a regular expression, because the core of Tcl has no CSV parser. The `json` task of `tclsh` uses tcllib `json` and `json::write`. `tclsh` has no `tls` program: Tcl 8.6 has no TLS in its core, and the tcltls package needs OpenSSL.
- `py/`: Python with its standard library.
- `go/`: Go with its standard library, built with `go build`.
- `zig/`: Zig with its standard library, built with `-OReleaseFast`. The Zig standard library has no regular expressions, CSV parser, or template engine, so `weblog`, `csv`, and `template` use a small hand-written scan.
- `gen.py` makes the inputs from fixed seeds.
