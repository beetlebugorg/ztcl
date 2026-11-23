# Roadmap

## Tcl 9

ztcl is measured against Tcl 8.6.16 only. It makes no claim of Tcl 9 compatibility. The planned work:

1. Benchmark against the current 9.x release: `python3 -I tools/bench.py --tclsh <path to tclsh9>`.
2. Run the 9.x test suite: `tools/suite.sh -t <9.x tag>`.
3. List where Tcl 8.6 and Tcl 9 differ, so that ztcl can choose a behavior for each difference.

## Other known gaps

- A hash table for dicts.
- Big integers, or a documented choice to keep 64-bit wrap.
- `info frame`, `trace`, and `tcl::prefix`.
- Error codes of the core commands, for example `ARITH DIVZERO`.
- The rest of `namespace`: `path`, `unknown`, and `forget`.
- A reset that keeps the commands and frees the values of one evaluation.
