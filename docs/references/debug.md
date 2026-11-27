# References for the debugging tools

The probes of `ztcl::probe` (issue #256) use ideas from these tools. ztcl copies no code from them. Only their documentation was read.

## DTrace

The probe model of DTrace: a probe at a named place of a running program, an optional predicate, and an action that records values into a buffer, with no change to the program. https://illumos.org/books/dtrace/

**How ztcl uses it:** `ztcl::probe add` has a target, a condition (`-if`, the predicate), and a capture list (the action). The records go in a ring buffer of the interpreter, and a query reads them later.

## Tcl `trace`

The variable and execution traces of Tcl 8.6, as `docs/references/tcl.md` lists them. https://www.tcl-lang.org/man/tcl8.6/TclCmd/trace.htm

**How ztcl uses it:** a variable probe and a command probe are entries of the same cells and wrappers that `trace.zig` makes for `trace add`. A probe entry runs no script and uses no compute units.
