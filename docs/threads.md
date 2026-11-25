# Threads

The capability `thread` adds the commands of the Tcl Thread package: `thread::*`, `tsv::*`, `tpool::*`, and the mutexes and conditions of `thread::mutex`, `thread::rwmutex`, and `thread::cond`. The embedder turns it on and sets its limits. This page has the model, the choices, and the differences from the Thread package. [The task list](threads-tasks/README.md) has the order of the work. [References](references/thread.md) lists the manual pages that the commands follow.

## The model

- Each thread has one interpreter, and the threads share no interpreter data. Each thread has its own heap, collector, JIT state, event loop, channels, and child interpreters.
- No value crosses threads by pointer. A message, a result, and each value of `tsv` and `tpool` cross as a deep copy.
- The host interpreter is the main thread of a group. Each thread that a script makes joins the group of its creator. The group has the registry of the threads, the shared variables, the pools, the mutexes, and the conditions. Two hosts have two groups, and a script of one group cannot name a thread of the other.
- A thread id has the form `tid0x` and a hex counter, for example `tid0x2`. The id has no address.

## The capability and the limits

`Interp.allow` with `Capability.thread` turns on the commands. The runner flag is `--allow thread`. The embedder sets `Interp.thread_limits` before the call:

| Field | Default | What it limits |
|---|---|---|
| `max_threads` | 8 | The threads that run at one time, the workers of the pools included. The main thread does not count. |
| `step_limit` | the step limit of the host | The steps of one thread. |
| `mem_limit` | 256 MiB | The bytes of the heap of one thread. |
| `total_steps` | no limit | The steps of all threads together. |
| `total_mem` | 1 GiB | The bytes of all threads together, with the shared variables, the queues, and the JIT data of the threads. |
| `max_queue` | 10 000 | The messages that wait in the queue of one thread. |

- A new thread gets its step limit from `total_steps` at its start, and the steps that it did not use go back at its end. So the sum of the steps of the threads is at most `total_steps`.
- The allocator of a thread adds each byte to an atomic count of the group. When the count passes `total_mem`, the allocation fails, and the thread stops with an error.
- A thread that passes a limit stops alone. The other threads and the host keep running. The error goes to the joiner, to the procedure of `thread::errorproc`, or to the output.
- A new thread has the capabilities of its creator, the JIT options of its creator, and the collector settings of its creator (`gc_on` and the stress mode). A child interpreter of a thread has no `thread` capability.
- The allocator of the embedder must be safe for threads. The output callback runs under a lock of the group, so the callback needs no lock of its own.

With the capability on, a script is not deterministic: the order of the events of two threads depends on the system.

## Messages

A message is a script, a result, or a job. The sender copies each value into a neutral form in the memory of the group. The form keeps the kind of a value: an integer, a double, a string, or a list of such values. So a list of numbers stays a list of numbers, and the receiver does no parse. The receiver copies the neutral form into its own heap on its own thread. Only the owner thread of a heap allocates from it.

A list deeper than 200 levels crosses as its string form. The copy then needs no deep recursion.

### No frozen shared form

ztcl has no frozen, read-only form of a value that two threads share. A value of ztcl is not immutable in memory:

- `List.append` writes after the view, into the spare room of the buffer, and changes `ListObj.used`.
- A dict lookup makes the hash table of a large dict at its first use, in `ListObj.index`.
- `append` writes after a string that ends at the used part of its buffer.

A shared form needs a buffer kind that each of these paths copies first, and a mark of each heap that tells the owner of the shared buffer when no thread holds it. This is future work. A large message costs one copy at each end.

## The thread commands

| Command | ztcl behavior |
|---|---|
| `thread::create ?-joinable? ?-preserved? ?script?` | Starts a thread and waits until its interpreter exists. With no script, the thread runs `thread::wait`. Without `thread::wait`, the thread ends at the end of its script. |
| `thread::send ?-async? ?-head? id script ?varname?` | Queues the script at the target, or at the head with `-head`. Without `-async`, the sender waits for the result. While it waits, it runs the scripts that other threads send to it, so two threads that send to each other do not deadlock. With `varname`, the result goes to the variable, and the command gives the return code. With `-async` and `varname`, the variable gets the result later, in the event loop of the sender. A send to the own thread runs the script at once. | A send to an id with no thread gives `thread "tid0x9" does not exist`. A send that waits gives `target thread died` when its target ends first.
| `thread::broadcast script` | Sends the script with `-async` to each other thread. |
| `thread::wait` | Runs the event loop of the thread until a release ends it. |
| `thread::preserve ?id?`, `thread::release ?-wait? ?id?` | Change the reference count. At zero or below, `thread::wait` returns and the thread ends. `-wait` waits for the end. |
| `thread::join id` | Waits for the end of a joinable thread and gives its exit status. |
| `thread::id`, `thread::names`, `thread::exists id` | The own id, the ids of the running threads, and a test for one id. |
| `thread::exit ?status?` | Ends the thread. `catch` cannot catch it. The main thread gives an error. |
| `thread::cancel ?-unwind? id ?result?` | Stops the script of a thread at its next safe point. A cancel of a thread that runs no script has no effect, as in the Thread package. `-unwind` gives an error that `catch` cannot catch. The main thread cannot be the target. |
| `thread::unwind` | The same as `thread::release` for the own thread. |
| `thread::errorproc ?proc?` | Sets the procedure that gets the errors of all threads: `proc id errorInfo`. It runs in the thread that set it. |
| `thread::configure id ?option? ?value?` | `-eventmark N` makes `thread::send -async` wait while the queue of the target has N messages. `-unwindonerror bool` ends the thread after a send with an error. |
| `thread::eval ?-lock mutex? arg ?arg ...?` | Runs the script while it holds the mutex, or a mutex of the group. |
| `thread::transfer id channel`, `thread::detach channel`, `thread::attach channel` | Move a file or socket channel between threads. A server socket and a command pipeline stay with their thread. The move removes the `fileevent` handlers of the channel. The channel commands exist only on Linux. |

## The shared variables

`tsv` keeps arrays of the group. Each array has its own lock, so two threads that use two arrays do not wait for each other. The table of the arrays has a lock of its own, which a command holds only to find or make an array.

- A value of an element is in the neutral form. A list keeps its elements as a list, so `tsv::lappend`, `tsv::lpush` at the end, and `tsv::lpop` at the end take amortized constant time with no parse.
- The lock of an array is recursive for its thread. `tsv::lock array script` holds it while the script runs, and each `tsv` command of the script on that array runs in the same lock. The lock goes free when the script ends, also with an error.
- `tsv::object array element` gives a command that runs each `tsv` command on that element.
- The commands are `set`, `get`, `unset`, `exists`, `pop`, `move`, `names`, `incr`, `append`, `lappend`, `linsert`, `lreplace`, `llength`, `lindex`, `lrange`, `lsearch`, `lset`, `lpop`, `lpush`, `array set|get|names|size|reset`, `lock`, `object`, `handlers`, and the keyed lists `keylset`, `keylget`, `keylkeys`, and `keyldel`. `array bind` and the persistent storage handlers are absent.

## The thread pools

`tpool::create` makes a pool of worker threads. A worker is a thread of the group with its own interpreter. It runs `-initcmd` one time and then keeps its interpreter between jobs, so a proc of `-initcmd` compiles one time for each worker.

- `tpool::post` queues a job and starts a worker when no worker is idle and the pool has fewer than `-maxworkers`. `-nowait` queues the job and starts no worker when one exists. `-detached` keeps no result.
- `tpool::wait` waits until one job of the list is done and gives the done jobs. `tpool::cancel` removes jobs that did not start. `tpool::get` gives the result or the error of a done job and forgets the job.
- A worker with no job for `-idletime` seconds ends, down to `-minworkers` workers. It runs `-exitcmd` before its end.
- `tpool::suspend` stops the start of new jobs, and `tpool::resume` starts them again. `tpool::preserve` and `tpool::release` count the references. At zero, the pool ends its workers.
- The workers count in `max_threads`. A post that needs a worker when no thread is free waits for a free worker of the pool. With no worker at all, it gives an error.

## The mutexes and the conditions

`thread::mutex`, `thread::rwmutex`, and `thread::cond` give handles of the group (`mid0`, `rwmid0`, `cid0`). A handle is a name in a table of the group, so a bad name is an error and never a bad pointer.

- An exclusive mutex gives an error when its thread locks it again. `-recursive` allows that.
- A lock and a condition wait in slices of 50 ms. After each slice, the thread checks its stop flag. So a cancel, a teardown, or the end of the group stops a thread that waits.
- A mutex that a thread holds at its end goes free. Another thread then gets it.
- `destroy` of a mutex that a thread holds, or of a condition that a thread waits on, is an error.

## The event loop

The queue of a thread is a source of the event loop. `vwait`, `update`, and `thread::wait` run the scripts of the queue. A thread without the `event` capability has `thread::wait` and runs only its queue.

- A wait with no timer and no channel blocks on the condition of the queue. In the main thread, `vwait` blocks only when another thread exists. Otherwise it gives the error of Tcl: `would wait forever`.
- A wait with channels polls the descriptors in slices of 10 ms and checks the queue between the slices.

## Stops, cancels, and teardown

A thread checks a stop flag at its safe points. Another thread sets the flag and then writes zero to `mem_limit` of the target interpreter. Each safe point of the interpreter and of the JIT code already compares the memory count with `mem_limit`, so the next safe point calls `Interp.memPoint`. There the target restores its limit and reads the flag. The fast path of the interpreter and of the JIT has no new check.

- The flag is atomic. The write of `mem_limit` is an aligned word that only the target restores. The other thread sets the flag and stores the zero under the lock of the worker. The target reads the flag and restores the limit under the same lock. So a cancel is never lost, and no zero store comes after a restore. `Interp.overLimit` compares a thread interpreter with the limit of its worker, so a memory check between the two steps gives no false error.
- A thread that runs in a child interpreter sees the cancel when the call into the child returns. The step limit of the thread bounds that call.
- A thread deletes its own interpreter, the JIT code included, on its own thread after its script ends. So no JIT code of a thread runs when its interpreter goes.
- When the host ends (`deinit` or `reset`), the group sets the stop flag of each thread, wakes each wait, and joins each thread. A thread with no step limit in a loop with no safe point can delay that. Set a step limit for untrusted scripts.

## Compiled code

A proc goes to a thread as its text in a script. Each thread compiles its own bytecode and its own JIT code.

The bytecode compiler inlines core commands such as `set` and `incr`. A command of the same name in another namespace stops the inline forms in the whole interpreter, because a call in that namespace finds that command first. The commands of `tsv` (`tsv::set`, `tsv::incr`, and the others) do not stop them. The cost of that rule: compiled code in the namespace `tsv`, for example a proc `tsv::helper` that calls `set`, runs the core `set` and not `tsv::set`. Tcl runs `tsv::set` there. Code outside the namespace `tsv` gets the same command as in Tcl. Without this rule, the commands of `tsv` stop the inline forms in each interpreter with the capability. A shared, read-only bytecode needs a `Code` with no cache of the interpreter in it: today a `Code` holds the slot hints, the command sites, and the epoch of its interpreter. Shared JIT code needs the same, and the W^X region of one thread then holds code for many. Both are future work.

## Locks and waits

Zig 0.16 has no `std.Thread.Mutex` or `std.Thread.Condition`. The locks are `std.Io.Mutex` on the instance `std.Io.Threaded.global_single_threaded`, so the library needs no `Io` from the embedder. A wait is a wake-up counter on a futex (`Io.futexWaitTimeout`) with a time limit of one slice. This form also gives the time limit of `thread::cond wait`, which `std.Io.Condition` does not have.

## Platforms

The commands use `std.Thread`, so they build for Linux, macOS, and Windows. The channel commands of `thread::transfer`, `thread::detach`, and `thread::attach` need the channel capability, which exists only on Linux. The WebAssembly build has no threads yet, and the capability adds no command there. Task 14 adds them. ThreadSanitizer runs on Linux: `tools/tsan.sh`.

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
| `thread::transfer`, `thread::detach`, and `thread::attach` | 06 | Done on Linux. The move removes the `fileevent` handlers of the channel, as in `tclsh`. |
| The thread tests of `socket.test` and `unixNotfy.test` | 07 | Done: 12 of 12 pass. |
| The tests of the limits, the teardown, and the races | 08 | Done: 11 files in `tests/thread/`, each with 20 runs in a row in the normal, JIT, and gc-stress modes. |
| ThreadSanitizer | 09 | Done: `tools/tsan.sh`. The build reports a planted race and the stop flag, and the thread tests give no report with one suppression. |
| The benchmarks | 10 | Done: [the table](testing.md#threads). Each benchmark is as fast as `tclsh` or faster. |
| macOS | 11 | Not done. The CI job `Test (macos-latest)` builds the code and passes. The files of `tests/thread/` did not run on macOS yet. |
| Windows | 12 | Not done. The CI job `Test (windows-latest)` builds the code and passes. The files of `tests/thread/` did not run on Windows yet. |
| The counts and the docs | 13 | Done. |
| WebAssembly with Web Workers | 14 | Not done. The plan is in [task 14](threads-tasks/14-wasm-workers.md). |

## Decisions

The user approved these three choices of the plan.

1. The stop flag uses the memory check (see above). Decided. The fast paths of `vm.zig` and of the JIT do not change. The other choice was an atomic load in the step check of each safe point, which changes `vm.zig` and the templates of both tiers. The cost of the plan is one store from another thread to `mem_limit`. ThreadSanitizer reports it as a race, so its run needs one suppression for that field.
2. The default limits are the values of the table above. Decided.
3. The suite turns on `thread` for each file. Decided. A file that tests `info commands` or the namespaces can change. Task 02 checks each file of `tools/suite.sh -a`.

The user made two more decisions during the work:

4. `thread::detach` removes the `fileevent` handlers of the channel, as `tclsh` does. This changed rule 2 of task 06, and the tests `socket-13.2.tr2` and `socket-13.2.cl2` pass.
5. The commands of `tsv` stay out of the shadow count of the inline forms. See "Compiled code" for the cost.

## WebAssembly

[Task 14](threads-tasks/14-wasm-workers.md) adds threads to the WebAssembly build. Each thread is a Web Worker, or a `worker_threads` worker in Node.js, with its own instance of the module. A message is the `Shared` form as bytes in `postMessage`.

- On a cross-origin isolated page and in Node.js, the main interpreter also runs in a worker, and each command works. The shared tables, the queues, the stop flags, and the group totals are in a `SharedArrayBuffer` under `Atomics`.
- Without cross-origin isolation, only the commands that do not wait work. Each command that waits gives an error that names the missing isolation. Only the limits of one thread apply.
- GitHub Pages cannot set the headers COOP and COEP. A service worker can add them on a static site.

## Future work

- A frozen shared form of large values (see above).
- Bytecode and JIT code that threads share (see "Compiled code").
- `ttrace`, `tsv::array bind`, and the storage handlers of `tsv`.

## Differences from the Thread package

- No value is shared by pointer, and `tsv` values keep their list and number forms.
- Each thread has limits, and a group has totals.
- The `ttrace` package, `tsv::array bind`, and the `-eventmark` wait of `thread::broadcast` are absent.
- `thread::cancel` reaches a thread in a child interpreter only when the child returns.
