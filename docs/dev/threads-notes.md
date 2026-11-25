# Threads: notes for contributors

These notes were part of [the threads page](../threads.md). They have the internals, the state of each part, and the decisions.

## No frozen shared form

ztcl has no frozen, read-only form of a value that two threads share. A value of ztcl is not immutable in memory:

- `List.append` writes after the view, into the spare room of the buffer, and changes `ListObj.used`.
- A dict lookup makes the hash table of a large dict at its first use, in `ListObj.index`.
- `append` writes after a string that ends at the used part of its buffer.

A shared form needs a buffer kind that each of these paths copies first, and a mark of each heap that tells the owner of the shared buffer when no thread holds it. This is future work. A large message costs one copy at each end.

## Locks and waits

Zig 0.16 has no `std.Thread.Mutex` or `std.Thread.Condition`. The locks are `std.Io.Mutex` on the instance `std.Io.Threaded.global_single_threaded`, so the library needs no `Io` from the embedder. A wait is a wake-up counter on a futex (`Io.futexWaitTimeout`) with a time limit of one slice. This form also gives the time limit of `thread::cond wait`, which `std.Io.Condition` does not have.

## The tests of Tcl

`thread.test` has 52 tests. 18 of them need only the constraint `thread`. It is true when `package require Thread` works. The other 34 also need `drainEventQueue`, a procedure on the `testthread` command of the Tcl test binary, so they cannot apply. `tools/suite.sh -a` passes the 18 tests, with and without the JIT.

`socket.test` has 10 tests with the constraint `thread`, and `unixNotfy.test` has 2. The suite turns on the capability for each file. Each of the 12 tests passes: `socket.test` went from 147 to 157 passes, and `unixNotfy.test` from 0 to 2. [Compatibility](compatibility.md) has the counts of each file.

## The state of each part

| Part | Task | State |
|---|---|---|
| The core: the group, the messages, and the stop flag | 01 | Done. |
| `thread::*` | 02 | Done. |
| `tsv::*` | 03 | Done. |
| The mutexes, the conditions, and `thread::eval` | 04 | Done. |
| `tpool::*` | 05 | Done. |
| `thread::transfer`, `thread::detach`, and `thread::attach` | 06 | Done on Linux and macOS. The move removes the `fileevent` handlers of the channel, as in `tclsh`. |
| The thread tests of `socket.test` and `unixNotfy.test` | 07 | Done: 12 of 12 pass. |
| The tests of the limits, the teardown, and the races | 08 | Done: 11 files in `tests/thread/`, each with 20 runs in a row in the normal, JIT, and gc-stress modes. |
| ThreadSanitizer | 09 | Done: `tools/tsan.sh`. The build reports a planted race and the stop flag, and the thread tests give no report with one suppression. |
| The benchmarks | 10 | Done: [the table](testing.md#threads). Each benchmark is as fast as `tclsh` or faster. |
| macOS | 11 | Done on arm64. Each file of `tests/thread/` passes 3 runs in a row with the JIT off, with tier 1, with tier 2, and with `--gc-stress 1`. A thread gets the root folder of the main thread, and a pipe ends the poll of a thread at a new message, as the eventfd does on Linux. A thread recurses to the same depth as the main thread. x86-64 macOS builds and did not run. |
| Windows | 12 | Not done. The CI job `Test (windows-latest)` builds the code and passes. The files of `tests/thread/` did not run on Windows yet. |
| The counts and the docs | 13 | Done. |
| WebAssembly with Web Workers | 14 | Done: `tools/wasm-threads.mjs` runs 9 files of `tests/thread/` in Node.js and in Chromium with cross-origin isolation, and the tests of the async mode in Chromium without it. |

## Decisions

The user approved these three choices of the plan.

1. The stop flag uses the memory check (see above). Decided. The fast paths of `vm.zig` and of the JIT do not change. The other choice was an atomic load in the step check of each safe point, which changes `vm.zig` and the templates of both tiers. The cost of the plan is one store from another thread to `mem_limit`. ThreadSanitizer reports it as a race, so its run needs one suppression for that field.
2. The default limits are the values of the table above. Decided.
3. The suite turns on `thread` for each file. Decided. A file that tests `info commands` or the namespaces can change. Task 02 checks each file of `tools/suite.sh -a`.

The user made two more decisions during the work:

4. `thread::detach` removes the `fileevent` handlers of the channel, as `tclsh` does. This changed rule 2 of task 06, and the tests `socket-13.2.tr2` and `socket-13.2.cl2` pass.
5. The commands of `tsv` stay out of the shadow count of the inline forms. See "Compiled code" for the cost.

## Future work

- A frozen shared form of large values (see above).
- Bytecode and JIT code that threads share (see "Compiled code").
- `ttrace`, `tsv::array bind`, and the storage handlers of `tsv`.

