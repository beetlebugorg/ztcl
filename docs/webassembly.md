# WebAssembly

`zig build wasm` builds the interpreter for the browser and for Node.js. The module runs Tcl scripts with an exact compute limit and a memory limit, so a page can run scripts that its users write. [The playground](https://beetlebug.org/ztcl/playground/) uses this build.

The WebAssembly build has the interpreter only, with no JIT. It has no command that reaches the host, and it has no capability that an embedder can turn on: no files, sockets, `exec`, `clock`, `interp`, or event loop. `coroutine` is present and returns an error. The `point` command is not installed.

## Install from npm

The package [`@beetlebug/ztcl`](https://www.npmjs.com/package/@beetlebug/ztcl) has `ztcl.wasm`, the JS module, the worker, and the TypeScript types. It works with a bundler, in Node.js, and from a CDN with no build step. See [Install](install.md#npm).

```sh
npm install @beetlebug/ztcl
```

```js
import { Interp } from "@beetlebug/ztcl";

const tcl = await Interp.create({ computeLimit: 1_000_000, memLimit: 64 << 20 });
console.log(tcl.eval("expr {6 * 7}").result); // 42
```

With no source, `Interp.create` and `WorkerInterp` load the `ztcl.wasm` file next to `ztcl.mjs`.

## Build

```sh
zig build wasm
```

The result is `zig-out/lib/ztcl.wasm`. It builds in `ReleaseSmall`. With Zig 0.16.0, the file is 825 KB, and 287 KB with `gzip -9`. The module has no imports.

## Load the module

`web/ztcl.mjs` is a small ES module over the exports. It runs in a page, in a Web Worker, and in Node.js 22 or later. Copy `web/ztcl.mjs`, `web/ztcl-worker.mjs`, and `ztcl.wasm` to your site.

In a page:

```html
<script type="module">
import { Interp } from "./ztcl.mjs";

const tcl = await Interp.create("./ztcl.wasm", {
  computeLimit: 1_000_000,
  memLimit: 64 << 20,
  onOutput: (text) => console.log(text),
});
const r = tcl.eval("puts hello; expr {6 * 7}");
// r is { ok: true, result: "42", output: "hello\n" }
</script>
```

Serve the file with the type `application/wasm`. Then `compile` uses `WebAssembly.compileStreaming`.

In Node.js, give a file path or a `file:` URL:

```js
import { Interp } from "./web/ztcl.mjs";

const tcl = await Interp.create("zig-out/lib/ztcl.wasm", { computeLimit: 1_000_000 });
console.log(tcl.eval("string repeat ab 3").result); // ababab
tcl.close();
```

## The JS module

| Function or field | Use |
|---|---|
| `compile(source)` | Compiles `ztcl.wasm`. `source` is a URL, a file path in Node.js, a `Response`, bytes, or a `WebAssembly.Module`. With no source, it is the `ztcl.wasm` file next to `ztcl.mjs`. |
| `Interp.create(source, options)` | Makes an interpreter in a new WebAssembly instance. `source` is as for `compile`, and it can be left out: `Interp.create(options)`. Compile once and pass the module to make many interpreters. |
| `options.computeLimit` | The compute units of each `eval`. `null` is no limit, and it is the default. |
| `options.memLimit` | The memory limit in bytes. The default is 2 GiB. |
| `options.onOutput(text)` | Gets the text of `puts` when each `eval` ends. |
| `interp.eval(script)` | Runs a script. Returns `{ ok, result, output }`. `result` is the value of the script, or the error message when `ok` is false. |
| `interp.computeLimit`, `interp.memLimit` | Change the limits for the next `eval`. |
| `interp.memorySize` | The size of the linear memory in bytes. The memory never shrinks, so this is the peak. |
| `interp.close()` | Frees the interpreter. |
| `options.allow` | A list of capabilities. `ztcl.wasm` has only `"file"`, for the files of a bundle. See [Bundle a script](#bundle-a-script). |
| `interp.run()` | Runs the scripts of a bundle. Returns `{ ok, result, output }`. |
| `interp.bundleSize` | The bytes of the scripts and files of a bundle, or 0. |
| `run(source, options)` | Makes an interpreter for the bundle `source`, runs its scripts, and frees it. Returns a promise of `{ ok, result, output }`. |
| `new WorkerInterp(wasmUrl, options)` | Runs scripts in a Web Worker (`ztcl-worker.mjs`). The options are as for `Interp.create`. `wasmUrl` can be left out. When `ztcl.mjs` comes from another origin, such as a CDN, the worker starts from a blob script that imports `ztcl-worker.mjs`. |
| `wasmURL()` | The URL of the `ztcl.wasm` file next to `ztcl.mjs`. |
| `worker.eval(script)` | Returns a promise of `{ ok, result, output, memorySize }`. |
| `worker.reset()` | Makes a new interpreter in the worker for the next `eval`. |
| `worker.stop()` | Ends the worker and the script in it. A pending `eval` gives `{ ok: false, result: "stopped" }`. The next `eval` starts a new worker. |

One interpreter keeps its procs and variables from one `eval` to the next. Each `Interp` has its own instance and its own linear memory, so `close` and a new `Interp` give the memory back to the host.

## The exports

`ztcl.mjs` uses these exports of `src/wasm.zig`. A host in another language can call them directly.

| Export | Use |
|---|---|
| `ztcl_new()` | Makes an interpreter. Returns a handle, or 0. The memory limit is 2 GiB, and there is no compute limit. |
| `ztcl_delete(h)` | Frees the interpreter. |
| `ztcl_alloc(len)`, `ztcl_free(ptr, len)` | Allocate and free memory for the text of a script. |
| `ztcl_eval(h, ptr, len)` | Runs the UTF-8 script at `ptr`. Returns 0 on success and 1 on an error. |
| `ztcl_result_ptr(h)`, `ztcl_result_len(h)` | The result or the error message. It is valid until the next `ztcl_eval`. |
| `ztcl_output_ptr(h)`, `ztcl_output_len(h)`, `ztcl_output_clear(h)` | The text of `puts` since the last clear. |
| `ztcl_set_compute_limit(h, n)` | Sets the compute units that are left, as a `u64` (a `BigInt` in JS). Each script uses compute units from this count. |
| `ztcl_set_mem_limit(h, bytes)` | Sets the memory limit. |
| `ztcl_set_gc_stress(h, n)` | A test mode: a collection at each Nth safe point. 0 turns it off. |
| `ztcl_bundle_size()` | The bytes of the payload of a bundle, or 0. |
| `ztcl_bundle_run(h)` | Runs the scripts of a bundle in order. Returns 0 on success and 1 on an error. |
| `ztcl_allow(h, bits)` | Turns on capabilities. This module has only `file` (16). Returns 0 on success, 1 when the memory ends, and 2 for another bit. |
| `memory` | The linear memory. |

`Interp.eval` sets the compute limit before each call. So the limit applies to each `eval`, and not to the sum of all calls.

## Limits

- **Compute units.** Each command and each loop pass uses compute units. At the limit, the script stops with the error `compute limit reached`. `catch` and `try` cannot catch it. The same script stops at the same point in each browser and in Node.js.
- **Memory.** At the limit, the script stops with the error `the script used too much memory`. `catch` cannot catch it. The heap has a hard cap of twice the limit, so the linear memory can grow to about twice the limit. A script that doubles a string with a limit of 64 MiB stopped with 116 MiB of linear memory.
- After the memory error, the data of the script can stay live above the limit. The next `eval` in the same interpreter runs a collection first. While the live data stays above the limit, only the hard cap applies, so the script can run and free its data with `unset`. When a collection brings the count below the limit, the limit applies again. Use `close` and a new `Interp` to give the memory back to the host.
- **Output.** The module has no imports, so `puts` goes into a buffer. `eval` returns the text, and `onOutput` gets it when the script ends. When `stop` ends a worker, the output of that script is lost.
- **Stop.** A script on the main thread blocks the page until it ends or hits a limit. Use `WorkerInterp` when a person must be able to stop a script.

## Bundle a script

`ztcl build --wasm` writes a copy of `ztcl.wasm` with Tcl scripts and read-only files in it. The command patches the module and needs no Zig toolchain.

```sh
zig build wasm
ztcl build --wasm --base zig-out/lib/ztcl.wasm --embed data -o app.wasm lib.tcl app.tcl
```

```
app.wasm: 1014418 bytes (ztcl.wasm: 1014098 bytes, bundle: 311 bytes)
```

- The scripts run in order in one interpreter, as `ztcl lib.tcl app.tcl` runs them. An error stops the scripts.
- `--embed PATH` adds a file, or each file below a folder. Give a relative path with no `..`. Use `--embed` more than one time for more paths.
- `--base FILE` is the module to copy. With no `--base`, the command uses the environment variable `ZTCL_WASM`, then `../lib/ztcl.wasm` from the folder of the `ztcl` program. Use the `ztcl.wasm` of the same version as the `ztcl` program, or the `ztcl.wasm` of the npm package. The module of `zig build wasm-threads` is not a base.
- The bundle has the source text of the scripts. The interpreter compiles them when the bundle runs.
- The bundle is the size of the base module plus the scripts and the files, plus a few bytes. The scripts and the files go in a new data segment above the initial memory, so the initial memory grows by the same number of 64 KiB pages.

Run the bundle with the JS module or the npm package:

```js
import { Interp, run } from "@beetlebug/ztcl";

// Make an interpreter, run the scripts, and free the interpreter.
const r = await run(new URL("./app.wasm", import.meta.url), {
  computeLimit: 1_000_000,
  memLimit: 64 << 20,
  allow: ["file"],
  onOutput: (text) => console.log(text),
});

// Or keep the interpreter, and call procs of the bundle after the run.
const tcl = await Interp.create("app.wasm", { allow: ["file"] });
tcl.run();
tcl.eval("sq 9");
tcl.close();
```

- `run()` returns `{ ok, result, output }` as `eval` does. On an error, `result` is `name:line: message`, as `ztcl` writes it.
- The compute limit and the memory limit apply as for `eval`. The compute limit of one `run()` applies to all the scripts together.
- The files of `--embed` and the scripts are under the mount `//zipfs:/app/`, with the path as given to `ztcl build`. A relative name is relative to the mount, so `open data/a.txt` reads the file of `--embed data`. With `allow: ["file"]`, the module has `source`, and `open` with the access `r`, `read`, `gets`, `eof`, and `close` on these files. `open` with another access gives the error `read-only file system`. A name outside the mount is not found. Without the capability, the module has none of these commands.
- `read` and `gets` give the bytes of the file. They do no encoding conversion and no end-of-line translation.
- A non-JS host calls `ztcl_new`, then `ztcl_allow(h, 16)` for the files, then `ztcl_bundle_run(h)`.

`node tools/wasm-bundle.mjs zig-out/bin/ztcl zig-out/lib/ztcl.wasm` checks that the output of each bundle equals the output of `ztcl`, the limits, and the files. The npm package tests run a bundle in Node.js and in headless Chromium.

The bundle is level 1 of [issue #3](https://github.com/beetlebugorg/ztcl/issues/3) in a short form, for a browser and Node.js. The full level 1 is a WASI component and follows [#2](https://github.com/beetlebugorg/ztcl/issues/2). The virtual file system of [#40](https://github.com/beetlebugorg/ztcl/issues/40), with `glob`, `file`, and zip archives, replaces the file table of the bundle.

## Compile procs to WebAssembly

`ztcl compile --wasm` makes a module with a WebAssembly function for each proc of a script. The runtime stays in the module for lists, strings, dicts, and each slow path. The command patches the module and needs no Zig toolchain.

```sh
zig build wasm-aot
ztcl compile --wasm -o app.wasm app.tcl
```

```
app.wasm: 6 procs compiled to 6 functions, 0 skipped
```

- The runtime is `ztcl-aot.wasm` from `zig build wasm-aot`: `ztcl.wasm` with the helpers of the compiled code as exports. `--runtime FILE` gives another path. With no `--runtime`, the command uses `../lib/ztcl-aot.wasm` from the folder of the `ztcl` program.
- `app.wasm` has the exports of `ztcl.wasm`, so `web/ztcl.mjs` and the npm package load it. The host runs the script with `eval` as before. When a proc body compiles to the same bytecode as a function of the module, that function runs in place of the interpreter.
- The command finds each `proc`, `method`, `constructor`, and `destructor` with literal words in the scripts, also in literal words that are scripts, such as the body of `namespace eval`. A proc that the script makes from a computed string runs in the interpreter. `--record FILE` adds the procs of a run in the record mode of the runtime (`ztcl_aot_record`), so each proc of that run gets a function.
- The output, the errors, `errorInfo`, the count of compute units, and the memory limit are the same as in the interpreter. A function keeps the state of the interpreter at each bytecode instruction, and each rare case calls the code of the interpreter. A function that the runtime cannot use, for example after a change of the runtime, leaves its proc in the interpreter.
- Coroutines are not in the WebAssembly build, so a compiled proc never suspends.

Speed in Node.js 26 on an x86-64 Linux machine with other load, the best of 5 runs of each `eval`, against `tclsh` 8.6.16 (the whole process, best of 5):

| Script | `ztcl.wasm` interpreter | Compiled | Compiled / interpreter | `tclsh` |
|---|---|---|---|---|
| `bench/sum.tcl` | 42.5 ms | 11.8 ms | 0.28 | 60.2 ms |
| `bench/foreach.tcl` | 33.0 ms | 17.8 ms | 0.54 | 35.0 ms |
| `bench/readloop.tcl` | 23.7 ms | 13.4 ms | 0.56 | 29.3 ms |
| `bench/nested.tcl` | 77.6 ms | 49.6 ms | 0.64 | 75.6 ms |
| `bench/fib.tcl` | 29.6 ms | 19.8 ms | 0.67 | 52.7 ms |
| `bench/dict.tcl` | 51.7 ms | 36.4 ms | 0.70 | 50.5 ms |
| `bench/dsum.tcl` | 92.3 ms | 65.1 ms | 0.71 | 98.4 ms |
| `bench/strbuild.tcl` | 52.6 ms | 38.7 ms | 0.74 | 65.8 ms |
| `bench/dictgrow.tcl` | 145.5 ms | 128.7 ms | 0.88 | 107.4 ms |
| kostya `bf.tcl bench.b`, one run | 207.58 s | 148.38 s | 0.71 | 257.33 s |
| kostya `base64/test.tcl`, one run | 1.77 s | 1.80 s | 1.01 | 4.35 s |

The gain is in the bytecode of the procs. Work in the builtins, such as `binary encode base64`, runs at the same speed in both modules. The rows of `dictgrow.tcl` and `base64/test.tcl` are after the faster base64 code and the XxHash32 hash of dict keys on wasm32. Before them, `base64/test.tcl` ran in 4.54 s and `dictgrow.tcl` in 136.6 ms compiled. On wasm, `dictgrow.tcl` is still slower than `tclsh`: its time is in the hash table, the text of each key, and the `dict` command, and the native build of ztcl runs it in 73 ms against 108 ms for `tclsh`. `node tools/wasm-aot-bench.mjs --kostya bench/*.tcl` makes this table. `tools/wasm-aot.mjs`, `tools/wasm-aot-suite.mjs`, and `tools/wasm-aot-fuzz.sh` compare the compiled modules with the interpreter. [The design](dev/wasm-aot.md) has the details.

## Compile a point proc

`ztcl compile FILE -proc NAME -o OUT.wasm` makes a small module from one point proc: no interpreter and no imports. A host such as a slicer runs it over columns of points in its own memory.

```sh
ztcl compile tests/point/fuzzy.tcl -proc fuzzy -o fuzzy.wasm -manifest fuzzy.json
node examples/point-wasm/run.mjs fuzzy.wasm
```

```
fuzzy: 2000 points, 35 compute units
offset: 0.000000 -0.007489 -0.017769 -0.031562 ...
```

| Option | What it does |
|---|---|
| `-simd on\|off` | `on` (the default) uses wasm SIMD, two points in each `v128`. `off` makes a module for a runtime with no SIMD. |
| `-max-mem BYTES` | The size of the memory. The module cannot grow it, so `cap`, the most points for one call, comes from this size. The default is 16 MiB. |
| `-features a,b,...` | The names of the feature numbers, in order. |
| `-manifest FILE` | Writes a JSON fragment for the manifest of a host: the exports, the global of each column, the compute units, `cap`, the memory size, and an empty list of imports. |

The module of ABI version 1 has these parts:

- `memory`, with a fixed size.
- The `i32` globals `abi`, `cap`, `limits`, `in_<field>` for each parameter, `feature` for the feature number of each point (one byte), and `out_<column>` for each output that the proc writes. Each is a byte offset in `memory`.
- `run(n, seed, in_mask, out_mask, compute_limit) -> i64`. Bit k of `in_mask` marks the field k as present, in the order `x y z width height speed flow feature layer path dist`. Bit k of `out_mask` marks the output k, in the order `offset move_x move_y width flow speed skip`. The result is the count of compute units, -1 at the compute limit, or -2 when `n` is more than `cap`.
- The custom section `ztcl.point`: JSON with the proc, its parameters and outputs, the feature names, the block size, and the compute units of the setup and of one block of points.

The host writes the columns at the offsets, calls `run`, and reads the outputs. A module keeps no state between calls. The outputs of a call are equal, bit for bit, to `Program.run` of the native interpreter: `tools/point-wasm-diff.sh` checks each fixed proc of `tests/point/`. [The design](dev/wasm-compile.md) has the details, and `bench/point-wasm.tsv` has the speed against the native `Program.run`.

## Examples

The examples are in [`examples/web/`](../examples/web/). To run the browser examples, build the module and serve the root of the repository:

```sh
zig build wasm
python3 -m http.server --bind 127.0.0.1 8000
```

Then open `http://127.0.0.1:8000/examples/web/repl.html`, `rules.html`, or `worker.html`. `node tools/wasm-web.mjs zig-out/lib/ztcl.wasm` tests the JS module and the Node.js example.

### A REPL

[`repl.html`](../examples/web/repl.html) runs each line in one interpreter, so procs and variables stay. Up and Down go through the history. Each line can use 1,000,000 compute units.

```js
const tcl = await Interp.create("../../zig-out/lib/ztcl.wasm", {
  computeLimit: 1_000_000,
  memLimit: 64 << 20,
  onOutput: (text) => show(text),
});
const r = tcl.eval(line.value);
if (!r.ok) show(r.result, "bad");
```

### A rule engine

[`rules.html`](../examples/web/rules.html) lets the user write a `price` proc in Tcl. The page calls it for each line of an order, with 10,000 compute units and 8 MiB for each call. Select "A rule that never ends" and the Price column shows `stopped: compute limit reached`. The page stays live.

```js
const tcl = await Interp.create(module, { computeLimit: 100_000, memLimit: 8 << 20 });
const def = tcl.eval(ruleText);
tcl.computeLimit = 10_000;
for (const [item, qty, unit] of order) {
  const r = tcl.eval(`price ${Number(qty)} ${Number(unit)}`);
  cell.textContent = r.ok ? r.result : `stopped: ${r.result}`;
}
```

Put only numbers or quoted lists into the text of a command. A value from a user can contain `[`, `$`, or `;`.

### A Web Worker with Cancel

[`worker.html`](../examples/web/worker.html) runs a loop of 50 million passes in a worker. A clock updates while it runs, and Cancel ends the worker.

```js
const tcl = new WorkerInterp("../../zig-out/lib/ztcl.wasm", { memLimit: 64 << 20 });
const r = await tcl.eval(code);   // the page stays live
cancel.onclick = () => tcl.stop(); // r is { ok: false, result: "stopped" }
```

### Node.js

[`run.mjs`](../examples/web/run.mjs) runs a script file with limits:

```sh
node examples/web/run.mjs --compute 1000000 --mem 16 examples/web/scripts/forever.tcl
```

```
error: compute limit reached
49.6 ms, 9.2 MiB of linear memory
```

The second line goes to stderr, with the time of the script. The exit code is 1 on an error of the script. `--compute` sets the compute limit and `--mem` sets the memory limit in MiB.

### Point procs

The WebAssembly build does not install the `point` command and has no export to run a point program over typed arrays. [Point procs](embedding.md#point-procs) work in a Zig program.

## Threads

`zig build wasm-threads` makes two more modules with the capability `thread`. The JS module `web/ztcl-threads.mjs` (`ztcl/threads` in the npm package) loads them. Each ztcl thread runs in its own worker: a Web Worker in a browser, or a `worker_threads` worker in Node.js. The main interpreter runs in a worker too, so a wait never blocks the page.

```js
import { ThreadInterp } from "./ztcl-threads.mjs";

const t = await ThreadInterp.create({ allow: ["thread", "event"], limits: { maxThreads: 4 } });
const r = await t.eval("set id [thread::create]; thread::send $id {expr {6 * 7}}");
// r.result is "42"
t.close();
```

The host picks one of two modes:

| Mode | When | Module | Commands |
|---|---|---|---|
| `shared` | Node.js, or a page that is cross-origin isolated. | `ztcl-threads.wasm` | Each command of [Threads](threads.md), with `tsv`, the mutexes, the conditions, and `tpool`. The capabilities `event`, `clock`, `package`, and `interp` can also be on. |
| `async` | A page with no cross-origin isolation. | `ztcl-async.wasm` | `thread::create`, `thread::send -async`, `thread::broadcast`, `thread::wait` in a thread, `thread::id`, `thread::names`, `thread::exists`, `thread::preserve`, `thread::release`, and `tpool::create`, `tpool::post`, `tpool::get`, `tpool::names`, `tpool::preserve`, and `tpool::release`. |

- In the `shared` mode, all workers use one shared `WebAssembly.Memory`. Each worker has its own instance of the one compiled module, its own stack, and one interpreter with its own heap. The locks and the waits use `Atomics` on the shared memory, as the futex does on Linux. A value crosses threads as a copy, as on the native platforms. The limits of [Threads](threads.md#the-capability-and-the-limits) apply. The stacks of the threads are 8 MiB each, and the memory can grow to 2 GiB.
- In the `async` mode, each worker has its own memory. A message is a script, and a reply is the result in a byte form that keeps the kind of each value. The host routes them with `postMessage`. A worker runs a message only between scripts, so the variable of `thread::send -async id script var` gets its value after the current `eval` ends. Only the main interpreter can make threads and pools. Each command that waits gives an error that names the headers, for example `thread::send without -async needs a cross-origin isolated page (COOP and COEP headers)`. The commands of `tsv`, the mutexes, the conditions, `thread::join`, `thread::cancel`, and `tpool::wait` give the same error. `tpool::get` of a job that runs gives it too. Only the limits of one thread apply, and `max_threads` counts the threads of the main interpreter.
- A page is cross-origin isolated when its server sends `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`. [Embedding](embedding.md#threads-on-the-web) has a service worker for a host that cannot send these headers, such as GitHub Pages.

`tools/wasm-threads.mjs` runs the 9 files of `tests/thread/` that need no channel in Node.js and in headless Chromium on a server with the headers. It also runs `tests/web/threads-async.tcl` in Chromium on a server with no such headers.

## More

The [issues](https://github.com/beetlebugorg/ztcl/issues) track the planned WebAssembly work, such as WASI components.
