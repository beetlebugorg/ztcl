# References for threads

ztcl has no code of the Tcl Thread package. The commands follow its manual pages and the output of `tclsh` 8.6.16 with Thread 2.8.11.

## The Tcl Thread package

The Thread extension, Zoran Vasiljevic and the Tcl Core Team. https://core.tcl-lang.org/thread, version 2.8.11. The manual pages `thread.n`, `tsv.n`, `tpool.n`, and `ttrace.n` give the commands, their options, and their behavior.

**License:** Tcl/Tk License (BSD style). The terms are in [`licenses/tcl-license.txt`](../../licenses/tcl-license.txt).

**How ztcl uses it:** `src/thread.zig`, `src/threadcmd.zig`, `src/tsv.zig`, `src/tpool.zig`, and `src/tsync.zig` give the command names, the options, the results, and the main error messages of these pages. The authors read the pages and the output of `tclsh`. The design of the threads, the messages, the locks, and the limits is new.

## The thread tests of Tcl

The `tests/thread.test` file of Tcl 8.6.16, and the tests with the `thread` constraint in `socket.test` and `unixNotfy.test`. https://github.com/tcltk/tcl/tree/core-8-6-16/tests

**License:** Tcl/Tk License (BSD style)

**How ztcl uses it:** `tools/suite.sh` runs the files. The repository has no copy of them.

## Keyed lists

The keyed list form of TclX, as the `tsv::keyl*` commands of `tsv.n` describe it: a list of pairs of a key and a value, with a dot in a key for a nested list.

**License:** TclX license (BSD style).

**How ztcl uses it:** `src/tsv.zig` reads and writes the form. It has no code of TclX.
