# References for the debugging tools

The probes of `ztcl::probe` (issue #256) use ideas from these tools. ztcl copies no code from them. Only their documentation was read.

## DTrace

The probe model of DTrace: a probe at a named place of a running program, an optional predicate, and an action that records values into a buffer, with no change to the program. https://illumos.org/books/dtrace/

**How ztcl uses it:** `ztcl::probe add` has a target, a condition (`-if`, the predicate), and a capture list (the action). The records go in a ring buffer of the interpreter, and a query reads them later.

## Tcl `trace`

The variable and execution traces of Tcl 8.6, as `docs/references/tcl.md` lists them. https://www.tcl-lang.org/man/tcl8.6/TclCmd/trace.htm

**How ztcl uses it:** a variable probe and a command probe are entries of the same cells and wrappers that `trace.zig` makes for `trace add`. A probe entry runs no script and uses no compute units.

## rr

The record and replay debugger of Mozilla: a run writes its inputs from the system to a trace, and a replay gives the same inputs back, so a bug that shows once can be studied again with a debugger. https://rr-project.org/

**How ztcl uses it:** `ztcl debug --record` writes the inputs of the host to a tape, and `--replay` gives them back. The compute units of the interpreter are the time of each input, so a replay can add probes and still read each input at the same place.

## Debug Adapter Protocol

The protocol between an editor and a debugger, from the VS Code project: a message has a `Content-Length` header and a JSON body, and the requests set breakpoints, step, and read the stack and the variables. https://microsoft.github.io/debug-adapter-protocol/specification

**How ztcl uses it:** `ztcl debug --dap` (`src/dap.zig`) answers the requests of the specification for one thread. The stops come from the line hook of `probe.zig`, so a breakpoint uses the same `probe` instruction as a line probe.
