# WebAssembly

`zig build wasm` builds the interpreter for the browser and for Node.js. The module runs Tcl scripts with an exact step limit and a memory limit, so a page can run scripts that its users write. [The playground](https://beetlebug.org/ztcl/playground/) uses this build.

The WebAssembly build has the interpreter only, with no JIT. It has no command that reaches the host, and it has no capability that an embedder can turn on: no files, sockets, `exec`, `clock`, `interp`, or event loop. `coroutine` is present and returns an error. The `point` command is not installed.

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
  stepLimit: 1_000_000,
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

const tcl = await Interp.create("zig-out/lib/ztcl.wasm", { stepLimit: 1_000_000 });
console.log(tcl.eval("string repeat ab 3").result); // ababab
tcl.close();
```

## The JS module

| Function or field | Use |
|---|---|
| `compile(source)` | Compiles `ztcl.wasm`. `source` is a URL, a file path in Node.js, a `Response`, bytes, or a `WebAssembly.Module`. |
| `Interp.create(source, options)` | Makes an interpreter in a new WebAssembly instance. `source` is as for `compile`. Compile once and pass the module to make many interpreters. |
| `options.stepLimit` | The steps of each `eval`. `null` is no limit, and it is the default. |
| `options.memLimit` | The memory limit in bytes. The default is 2 GiB. |
| `options.onOutput(text)` | Gets the text of `puts` when each `eval` ends. |
| `interp.eval(script)` | Runs a script. Returns `{ ok, result, output }`. `result` is the value of the script, or the error message when `ok` is false. |
| `interp.stepLimit`, `interp.memLimit` | Change the limits for the next `eval`. |
| `interp.memorySize` | The size of the linear memory in bytes. The memory never shrinks, so this is the peak. |
| `interp.close()` | Frees the interpreter. |
| `new WorkerInterp(wasmUrl, options)` | Runs scripts in a Web Worker (`ztcl-worker.mjs`). The options are as for `Interp.create`. |
| `worker.eval(script)` | Returns a promise of `{ ok, result, output, memorySize }`. |
| `worker.reset()` | Makes a new interpreter in the worker for the next `eval`. |
| `worker.stop()` | Ends the worker and the script in it. A pending `eval` gives `{ ok: false, result: "stopped" }`. The next `eval` starts a new worker. |

One interpreter keeps its procs and variables from one `eval` to the next. Each `Interp` has its own instance and its own linear memory, so `close` and a new `Interp` give the memory back to the host.

## The exports

`ztcl.mjs` uses these exports of `src/wasm.zig`. A host in another language can call them directly.

| Export | Use |
|---|---|
| `ztcl_new()` | Makes an interpreter. Returns a handle, or 0. The memory limit is 2 GiB, and there is no step limit. |
| `ztcl_delete(h)` | Frees the interpreter. |
| `ztcl_alloc(len)`, `ztcl_free(ptr, len)` | Allocate and free memory for the text of a script. |
| `ztcl_eval(h, ptr, len)` | Runs the UTF-8 script at `ptr`. Returns 0 on success and 1 on an error. |
| `ztcl_result_ptr(h)`, `ztcl_result_len(h)` | The result or the error message. It is valid until the next `ztcl_eval`. |
| `ztcl_output_ptr(h)`, `ztcl_output_len(h)`, `ztcl_output_clear(h)` | The text of `puts` since the last clear. |
| `ztcl_set_step_limit(h, n)` | Sets the steps that are left, as a `u64` (a `BigInt` in JS). Each script uses steps from this count. |
| `ztcl_set_mem_limit(h, bytes)` | Sets the memory limit. |
| `ztcl_set_gc_stress(h, n)` | A test mode: a collection at each Nth safe point. 0 turns it off. |
| `memory` | The linear memory. |

`Interp.eval` sets the step limit before each call. So the limit applies to each `eval`, and not to the sum of all calls.

## Limits

- **Steps.** Each command and each loop pass uses steps. At the limit, the script stops with the error `step limit reached`. `catch` and `try` cannot catch it. The same script stops at the same step in each browser and in Node.js.
- **Memory.** At the limit, the script stops with the error `the script used too much memory`. `catch` cannot catch it. The heap has a hard cap of twice the limit, so the linear memory can grow to about twice the limit. A script that doubles a string with a limit of 64 MiB stopped with 116 MiB of linear memory.
- After the memory error, the data of the script can stay live above the limit. The next `eval` in the same interpreter runs a collection first. While the live data stays above the limit, only the hard cap applies, so the script can run and free its data with `unset`. When a collection brings the count below the limit, the limit applies again. Use `close` and a new `Interp` to give the memory back to the host.
- **Output.** The module has no imports, so `puts` goes into a buffer. `eval` returns the text, and `onOutput` gets it when the script ends. When `stop` ends a worker, the output of that script is lost.
- **Stop.** A script on the main thread blocks the page until it ends or hits a limit. Use `WorkerInterp` when a person must be able to stop a script.

## Examples

The examples are in [`examples/web/`](../examples/web/). To run the browser examples, build the module and serve the root of the repository:

```sh
zig build wasm
python3 -m http.server --bind 127.0.0.1 8000
```

Then open `http://127.0.0.1:8000/examples/web/repl.html`, `rules.html`, or `worker.html`. `node tools/wasm-web.mjs zig-out/lib/ztcl.wasm` tests the JS module and the Node.js example.

### A REPL

[`repl.html`](../examples/web/repl.html) runs each line in one interpreter, so procs and variables stay. Up and Down go through the history. Each line can use 1 000 000 steps.

```js
const tcl = await Interp.create("../../zig-out/lib/ztcl.wasm", {
  stepLimit: 1_000_000,
  memLimit: 64 << 20,
  onOutput: (text) => show(text),
});
const r = tcl.eval(line.value);
if (!r.ok) show(r.result, "bad");
```

### A rule engine

[`rules.html`](../examples/web/rules.html) lets the user write a `price` proc in Tcl. The page calls it for each line of an order, with 10 000 steps and 8 MiB for each call. Select "A rule that never ends" and the Price column shows `stopped: step limit reached`. The page stays live.

```js
const tcl = await Interp.create(module, { stepLimit: 100_000, memLimit: 8 << 20 });
const def = tcl.eval(ruleText);
tcl.stepLimit = 10_000;
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
node examples/web/run.mjs --steps 1000000 --mem 16 examples/web/scripts/forever.tcl
```

```
error: step limit reached
49.6 ms, 9.2 MiB of linear memory
```

The second line goes to stderr, with the time of the script. The exit code is 1 on an error of the script. `--steps` sets the steps and `--mem` sets the memory limit in MiB.

### Point procs

The WebAssembly build does not install the `point` command and has no export to run a point program over typed arrays. [Point procs](embedding.md#point-procs) work in a Zig program.

## Later

- [WASI preview 2 and the component model (#2)](https://github.com/beetlebugorg/ztcl/issues/2) adds the `ztcl` program and the library as components. A component host in any language can then run ztcl, and the root folder jail and the network policy map to WASI.
- [Compile Tcl scripts to WebAssembly modules (#3)](https://github.com/beetlebugorg/ztcl/issues/3).
- [ztk](https://beetlebug.org/ztk/), the Tk replacement on ztcl, will also run on the web.
