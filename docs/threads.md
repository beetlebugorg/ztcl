# Threads

The capability `thread` adds the commands of the Tcl Thread package: `thread::*`, `tsv::*`, `tpool::*`, and the mutexes and conditions of `thread::mutex`, `thread::rwmutex`, and `thread::cond`. The embedder turns it on and sets its limits. This page has the model, the limits, and the differences from the Thread package. [References](references/thread.md) lists the manual pages that the commands follow.

## Example

```tcl
set ids {}
for {set i 0} {$i < 4} {incr i} {
    lappend ids [thread::create -joinable [format {
        set sum 0
        for {set k 0} {$k < 1000000} {incr k} { incr sum %d }
        tsv::incr totals all $sum
    } $i]]
}
foreach id $ids { thread::join $id }
puts [tsv::get totals all]
```

```sh
$ ztcl --allow thread threads.tcl
6000000
```

## Speed

Each benchmark of `bench/` is as fast as `tclsh` 8.6.16 with Thread 2.8.11, or faster. Wall time in milliseconds, best of 5 runs, on a 4-core Intel Core i7-6700K. [Performance](performance.md#threads) has the method.

| Benchmark | ztcl | tclsh 8.6.16 |
|---|---|---|
| `thread_map.tcl`: 1,000,000 integers in 8 parts | 99 | 305 |
| `thread_pipe.tcl`: 4 stages, 100,000 messages | 605 | 706 |
| `thread_tsv.tcl`: 8 threads, 100,000 `tsv::incr` each, 8 elements | 1214 | 3276 |
| `thread_tpool.tcl`: 8 workers, 100,000 jobs | 466 | 639 |

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
| `compute_limit` | the compute limit of the host | The compute units of one thread. |
| `mem_limit` | 256 MiB | The bytes of the heap of one thread. |
| `total_compute` | no limit | The compute units of all threads together. |
| `total_mem` | 1 GiB | The bytes of all threads together, with the shared variables, the queues, and the JIT data of the threads. |
| `max_queue` | 10,000 | The messages that wait in the queue of one thread. |

- A new thread gets its compute limit from `total_compute` at its start, and the compute units that it did not use go back at its end. So the sum of the compute units of the threads is at most `total_compute`.
- The allocator of a thread adds each byte to an atomic count of the group. When the count passes `total_mem`, the allocation fails, and the thread stops with an error.
- A thread that passes a limit stops alone. The other threads and the host keep running. The error goes to the joiner, to the procedure of `thread::errorproc`, or to the output.
- A new thread has the capabilities of its creator, the JIT options of its creator, and the collector settings of its creator (`gc_on` and the stress mode). A child interpreter of a thread has no `thread` capability.
- The allocator of the embedder must be safe for threads. The output callback runs under a lock of the group, so the callback needs no lock of its own.

With the capability on, a script is not deterministic: the order of the events of two threads depends on the system.

## Messages

A message is a script, a result, or a job. The sender copies each value into a neutral form in the memory of the group. The form keeps the kind of a value: an integer, a double, a string, or a list of such values. So a list of numbers stays a list of numbers, and the receiver does no parse. The receiver copies the neutral form into its own heap on its own thread. Only the owner thread of a heap allocates from it.

A list deeper than 200 levels crosses as its string form. The copy then needs no deep recursion.

ztcl has no frozen, read-only form of a value that two threads share, so a large message costs one copy at each end.

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
| `thread::transfer id channel`, `thread::detach channel`, `thread::attach channel` | Move a file or socket channel between threads. A server socket and a command pipeline stay with their thread. The move removes the `fileevent` handlers of the channel. The channel commands exist on Linux and macOS. |

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
- A thread that runs in a child interpreter sees the cancel when the call into the child returns. The compute limit of the thread bounds that call.
- A thread deletes its own interpreter, the JIT code included, on its own thread after its script ends. So no JIT code of a thread runs when its interpreter goes.
- When the host ends (`deinit` or `reset`), the group sets the stop flag of each thread, wakes each wait, and joins each thread. A thread with no compute limit in a loop with no safe point can delay that. Set a compute limit for untrusted scripts.

## Isolated threads

`thread::create -isolation process` runs the thread in a child process (ztcl#209). The child is the ztcl runner with one interpreter, and it talks to the parent over the protocol of `docs/dev/isolation.md`: sealed frames on a socket pair. A crash, a memory error, or a bad C package in the child ends only the child.

```tcl
set t [thread::create -isolation process {proc sq x {expr {$x * $x}}; thread::wait}]
puts [thread::send $t {sq 12}]   ;# 144, from another process
```

- `thread::send`, `-async` with a variable, a send of the child to another thread, the errors with their codes, `thread::cancel`, `thread::release`, `thread::exit`, `thread::join`, `thread::names`, and `thread::errorproc` work as for a thread of the level `interp`. The values keep their kinds.
- The child gets the capabilities, the compute limit, and the memory limit of the thread. The clock and the event loop of the child are those of the runner, when the creator has them.
- A child that ends with no exit, for example a kill from outside, ends the thread: a send that waits gives `target thread died`, `thread::join` gives 1, and `thread::errorproc` gets the error.
- At the end of the group, a child that does not stop within 2 seconds gets SIGKILL.
- The runner starts the child (`Interp.iso_runner`, which the runner sets to itself). An embedder that is not the runner sets `iso_runner` to a ztcl runner, or gets `ZTCL ISOLATION RUNNER`.
- In this version the level runs on macOS, with no sandbox yet. Linux and Windows get it with their sandboxes. `tsv`, the mutexes, the conditions, `thread::transfer`, and a thread that the child creates are not yet available in the child: they give an error there. The levels `wasm`, `vm`, and `vm-confidential` give `ZTCL ISOLATION LEVEL`.

> [!WARNING]
> In this version a child of the level `process` has no sandbox: it has the files and the network of the user, as far as its capabilities let its script reach them. A send from the child to the parent runs in the parent with the power of the parent, as with any thread.

## Compiled code

A proc goes to a thread as its text in a script. Each thread compiles its own bytecode and its own JIT code.

The bytecode compiler inlines core commands such as `set` and `incr`. A command of the same name in another namespace stops the inline forms in the whole interpreter, because a call in that namespace finds that command first. The commands of `tsv` (`tsv::set`, `tsv::incr`, and the others) do not stop them. The cost of that rule: compiled code in the namespace `tsv`, for example a proc `tsv::helper` that calls `set`, runs the core `set` and not `tsv::set`. Tcl runs `tsv::set` there. Code outside the namespace `tsv` gets the same command as in Tcl. Without this rule, the commands of `tsv` stop the inline forms in each interpreter with the capability.

## Platforms

The commands use `std.Thread`, so they build for Linux, macOS, and Windows. The channel commands of `thread::transfer`, `thread::detach`, and `thread::attach` need the channel capability, which exists on Linux and macOS. The default WebAssembly build (`ztcl.wasm`) has no threads. `zig build wasm-threads` makes two WebAssembly builds with threads. See "WebAssembly" below. ThreadSanitizer runs on Linux: `tools/tsan.sh`.

## WebAssembly

Each thread is a Web Worker, or a `worker_threads` worker in Node.js, with its own instance of the module. `web/ztcl-threads.mjs` is the host. [WebAssembly](webassembly.md#threads) has the API.

- On a cross-origin isolated page and in Node.js, the host uses `ztcl-threads.wasm`. All instances use one shared memory, so the group, the queues, `tsv`, the mutexes, the conditions, the stop flags, and the totals are in a `SharedArrayBuffer`. The code of the native platforms runs there. `src/webthread.zig` gives it the parts of `std.Thread` and `std.Io`: a thread start through the host, a futex on `memory.atomic.wait32`, a lock, and an allocator with a lock. The main interpreter also runs in a worker, because a browser does not allow `Atomics.wait` on its main thread. The output of the threads goes to the main worker, which sends it to the host every 50 ms.
- Without cross-origin isolation, the host uses `ztcl-async.wasm` (`src/webasync.zig`). Each instance has its own memory. A message is a script, and the reply is the result in a byte form that keeps the kind of each value. Only the commands that do not wait work. Each command that waits gives an error that names the missing isolation. Only the limits of one thread apply, and a stop is `Worker.terminate()`.
- GitHub Pages cannot set the headers COOP and COEP. A service worker can add them on a static site. [Embedding](embedding.md#threads-on-the-web) has the steps.

## Differences from the Thread package

- No value is shared by pointer, and `tsv` values keep their list and number forms.
- Each thread has limits, and a group has totals.
- The `ttrace` package, `tsv::array bind`, and the `-eventmark` wait of `thread::broadcast` are absent.
- `thread::cancel` reaches a thread in a child interpreter only when the child returns.
