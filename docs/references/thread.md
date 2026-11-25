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

## WebAssembly threads and workers

The threads proposal of WebAssembly (shared memory, `memory.atomic.wait32`, and `memory.atomic.notify`), and the HTML rules for `SharedArrayBuffer` and cross-origin isolation (the headers `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy`). https://github.com/WebAssembly/threads and https://html.spec.whatwg.org/multipage/browsers.html#cross-origin-isolation

**License:** W3C Software and Document License, and the WHATWG license (CC BY 4.0).

**How ztcl uses it:** `src/webthread.zig` and `web/ztcl-threads.mjs` follow the model of these documents: one shared memory, one instance of the module in each worker, and a futex on the atomic wait and notify. The thread start (a block with the stack, the thread-local data, and a record, and an export that sets the stack pointer) follows the WASI threads design of `std.Thread` in the Zig standard library (MIT). The code is new.

## A service worker for the headers of isolation

The method of `coi-serviceworker` by Guido Zuidhof: a service worker adds the headers COOP and COEP to each response of a static site, and the page loads one more time. https://github.com/gzuidhof/coi-serviceworker

**License:** MIT.

**How ztcl uses it:** `docs/site/playground/coi.js` uses the same method. The code is new.

## A pool of workers

Emscripten keeps a pool of workers for its threads, so a new thread needs no new worker. https://emscripten.org/docs/porting/pthreads.html

**License:** MIT and the University of Illinois/NCSA license.

**How ztcl uses it:** `web/ztcl-threads.mjs` keeps the workers of the threads that ended and gives each one the next thread. The code is new.
