# Roadmap

## Tcl 9

ztcl follows Tcl 8.6.16 and makes no claim of Tcl 9 compatibility. The baseline for Tcl 9.1.0 is in [Tcl 8.6 and Tcl 9](tcl9.md).

1. Decide on each proposed choice in that page.
2. Add the commands of Tcl 9 that the choices accept.

## Other known gaps

- `info frame`, `trace`, and `tcl::prefix`.
- Error codes of the core commands, for example `ARITH DIVZERO`.
- The rest of `namespace`: `path`, `unknown`, and `forget`.
- A `compact` that keeps the compiled forms of procs.
- An in-place write to an existing key of a dict at the global level.
- Cheaper proc frames.
- A cached list form for a string value. `llength` and `lindex` parse a string value again at each call.
