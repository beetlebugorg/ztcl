# Contributor docs

These files are the plans, the task lists, the reviews, and the test results of ztcl. The docs site does not publish them. The user docs are in [docs/](../) and on https://beetlebug.org/ztcl/.

| File | What it has |
|---|---|
| [design.md](design.md) | The design of the interpreter: values, bytecode, the evaluator, and the capabilities. Read it before you change the interpreter. |
| [testing.md](testing.md) | The test commands, the Tcl suite, the size report, and the benchmark commands. |
| [compatibility.md](compatibility.md) | The result of each test file of Tcl 8.6.16. `tools/suite-table.py` writes it. |
| [tcl9.md](tcl9.md) | The Tcl 9.1.0 baseline and the proposed choices. |
| [jit.md](jit.md), [jit-review.md](jit-review.md), [jit-tasks/](jit-tasks/README.md) | The JIT plan, its results, the review checklist, and the tasks. |
| [perf-review.md](perf-review.md) | A performance review: the slow paths, with a measure and a proposed change for each one. |
| [interp-spike.md](interp-spike.md) | The profile of the bytecode loop, and the measures of two superinstruction experiments (#130). |
| [stdlib.md](stdlib.md), [stdlib-tasks/](stdlib-tasks/README.md) | The plan of the built-in modules, and the tasks. |
| [threads-tasks/](threads-tasks/README.md), [threads-notes.md](threads-notes.md) | The tasks of threads, the state of each part, and the decisions. |
| [values.md](values.md), [values-tasks/](values-tasks/README.md) | The plan of faster values, and the tasks. |
| [wasi.md](wasi.md), [wasi-tasks/](wasi-tasks/README.md) | The plan of the WASI target, and the tasks. |
| [wasm-compile.md](wasm-compile.md), [wasm-compile-tasks/](wasm-compile-tasks/README.md) | The plan of point procs compiled to WebAssembly, and the tasks. |
| [wasm-aot.md](wasm-aot.md) | The design and the state of procs compiled to WebAssembly functions (`ztcl compile --wasm`). |
| [wasm-host-tasks/](wasm-host-tasks/README.md) | The tasks of the WebAssembly host API: point procs from JavaScript, live output, and capabilities of the page (#26). |
| [dom-tasks/](dom-tasks/README.md) | The tasks of the capability `dom`: DOM access for Tcl in the browser (#85). |
| [static-build.md](static-build.md) | The plan of static binaries with embedded files, the virtual file system, and cross-compiling (`ztcl build`). |
| [ports.md](ports.md) | The plan of the macOS and Windows ports. |
| [linux-tasks/](linux-tasks/README.md) | The tasks of `ztcl::linux`: desktop portals and D-Bus calls (#110). |
| [cext-tasks/](cext-tasks/README.md) | The tasks of Tcl packages with C modules, native and in WebAssembly (#1). |
| [roadmap.md](roadmap.md) | The old roadmap. The issues and the milestones on GitHub replace it. |
| [release.md](release.md), [npm.md](npm.md) | The release process and the npm package. |

## The test suites

- ztcl aims to become a complete drop-in replacement for Tcl. It is not one yet. The sandbox stays the default, and host access stays an explicit capability of the embedder.
- The test suite of Tcl 8.6.16 is the measure of compatibility. Of the 46 494 tests in all 152 files, ztcl passes 37 413 on the suite runner (80.5 %), fails 3 044, and 6 037 are blocked. Of the 29 990 tests in the 77 files in scope, it passes 27 182, fails 1 031, and 1 777 are blocked. Of those passes, 1 735 need a test-only command. With the default runner, the pass rate in scope is 84.9 %. [Compatibility](compatibility.md) has the result for each test file.
- On the 37 core test files of Tcl 9.1.0, ztcl passes 9 298 tests, fails 2 799, and skips 529. ztcl follows Tcl 8.6 and makes no claim of Tcl 9 compatibility. [Tcl 8.6 and Tcl 9](tcl9.md) lists the differences and the proposed choices.

