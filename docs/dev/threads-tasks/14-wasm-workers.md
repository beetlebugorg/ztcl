# Task 14: threads in WebAssembly with Web Workers

Platform: shared/web. Do this task after tasks 01 to 05 and 08 are merged. It uses their core.

## Goal

The `thread` capability works in the WebAssembly build. Each ztcl thread is a Web Worker in a browser, or a `worker_threads` worker in Node.js. Each worker runs its own instance of the wasm module with one interpreter, its own heap, and its own limits.

## The model

- The host compiles the module one time and gives the compiled module to each new worker. `thread::create` starts a worker with a new instance of that module.
- A message, a reply, and a job result are the `Shared` form of task 01, written to bytes. `thread::send -async` and each reply go through `postMessage` as those bytes. The receiver reads the bytes into its own heap.
- A wait (`thread::send` without `-async`, `thread::wait`, `thread::join`, `tsv::*`, the mutexes, and the conditions) needs `SharedArrayBuffer` and `Atomics.wait`. A browser allows `SharedArrayBuffer` only on a cross-origin isolated page (the headers COOP and COEP), and it does not allow `Atomics.wait` on its main thread.

## The two modes

| Mode | When | Commands |
|---|---|---|
| a: isolated | The page is cross-origin isolated, or the host is Node.js. | The main interpreter runs in a worker too, and each command works. The tables of `tsv`, the mutexes, the conditions, the queues, and the group totals are in a `SharedArrayBuffer`. `Atomics` guards them. A wait is `Atomics.wait` in slices of 50 ms, with the check of the stop flag after each slice, as on the native platforms. |
| b: not isolated | No `SharedArrayBuffer`. | `thread::create`, `thread::send -async` with a variable, `thread::broadcast`, the event loop, and `tpool` with results that come back as events. Each command that waits gives an error that names the missing cross-origin isolation. |

## Limits

- The compute limit and the memory limit of one thread work as on the native platforms. Each instance has its own memory, so the memory limit is the limit of that instance.
- In mode a, `total_compute` and `total_mem` use an atomic counter in the `SharedArrayBuffer`.
- In mode b, only the limits of one thread apply. `max_threads` is a count in the main instance.
- The stop flag is a word in the `SharedArrayBuffer` in mode a. In mode b, a stop is `Worker.terminate()`.

## Hosting

GitHub Pages cannot set the headers COOP and COEP. A service worker can add them to each response of a static site. Document this workaround in `docs/embedding.md`. If `docs/site/playground` exists on main at the time of this task, test the workaround on the playground.

## Files

- `src/wasm.zig`: the exports for a worker: the start of a thread interpreter, the bytes of a message in and out, and the wait hooks.
- `src/thread.zig`: an import of the host for the start of a thread, for a message, and for a wait, in place of `std.Thread` in the WebAssembly build.
- A JavaScript file of the host in `tools/` or `web/` with the worker code for the browser and for Node.js.
- `docs/threads.md`, `docs/embedding.md`: the two modes and the hosting.

## Rules

1. The native code paths of tasks 01 to 08 do not change.
2. No value crosses workers by pointer. A message is bytes.
3. The wasm build with the capability off has the same size class and the same exports as before. `node tools/wasm-smoke.mjs` passes.
4. The error of mode b names cross-origin isolation, for example: `thread::send without -async needs a cross-origin isolated page (COOP and COEP headers)`.

## Acceptance

- `CAP zig build wasm && node tools/wasm-smoke.mjs zig-out/lib/ztcl.wasm`.
- The files of `tests/thread/` that need no channel run in Node.js with `worker_threads` (mode a) and pass. CI runs them.
- The same files run in headless Chromium on a test server with the headers COOP and COEP (mode a).
- The tests of mode b run in headless Chromium on a test server with no such headers. Each command that waits gives the error of rule 4, and the async subset works.
- The limit tests of task 08 that apply to one thread pass in both modes.
