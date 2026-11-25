# {{name}}

ztcl is a Tcl interpreter in Zig. This package has the WebAssembly build and a small ES module over it. A page or a Node.js program runs Tcl scripts with an exact step limit and a memory limit, so it can run scripts that its users write.

- The module is 871 KB, or about 300 KB with gzip. It has no imports.
- It runs in a browser, in a Web Worker, and in Node.js 22.3 or later.
- It has types for TypeScript.

The docs are at [beetlebug.org/ztcl](https://beetlebug.org/ztcl/webassembly/). The source is at [github.com/beetlebugorg/ztcl](https://github.com/beetlebugorg/ztcl).

## Install

```sh
npm install {{name}}
```

## In a page with no build step

```html
<script type="module">
import { Interp } from "https://cdn.jsdelivr.net/npm/{{name}}@{{version}}/ztcl.mjs";

const tcl = await Interp.create({ stepLimit: 1_000_000, memLimit: 64 << 20 });
console.log(tcl.eval("expr {6 * 7}").result); // 42
</script>
```

The module loads `ztcl.wasm` from its own folder on the CDN. `WorkerInterp` also works from the CDN: it starts its worker from a small blob script that imports `ztcl-worker.mjs`. The jsDelivr form `https://cdn.jsdelivr.net/npm/{{name}}/+esm` resolves `ztcl.wasm` in the same folder, but no test runs it.

## With a bundler

```js
import { Interp, WorkerInterp } from "{{name}}";

const tcl = await Interp.create({
  stepLimit: 1_000_000,
  memLimit: 64 << 20,
  onOutput: (text) => console.log(text),
});
const r = tcl.eval("puts hello; expr {6 * 7}");
// r is { ok: true, result: "42", output: "hello\n" }
```

The module finds `ztcl.wasm` with `new URL("./ztcl.wasm", import.meta.url)`, and `WorkerInterp` starts its worker with `new Worker(new URL("./ztcl-worker.mjs", import.meta.url))`. `vite build` copies both files. For the Vite dev server, keep the package out of the dependency step, so the two files stay together:

```js
// vite.config.js
export default { optimizeDeps: { exclude: ["{{name}}"] } };
```

The tests of the package run Vite 7. Webpack 5 and Rollup also have support for the `new URL` form, but no test runs them. With another tool, copy `ztcl.wasm` to your site and give its URL to `Interp.create(url, options)`.

## In Node.js

```js
import { Interp } from "{{name}}";

const tcl = await Interp.create({ stepLimit: 1_000_000, memLimit: 64 << 20 });
const r = tcl.eval("proc sq {x} {expr {$x * $x}}; sq 12");
console.log(r.result); // 144
tcl.close();
```

## A worker that a person can stop

A script on the main thread blocks the page until it ends or hits a limit. `WorkerInterp` runs scripts in a Web Worker, and `stop()` ends the script at once.

```js
import { WorkerInterp } from "{{name}}";

const tcl = new WorkerInterp({ memLimit: 64 << 20 });
const r = await tcl.eval(code);    // the page stays live
cancel.onclick = () => tcl.stop(); // r is { ok: false, result: "stopped" }
```

The next `eval` after `stop` starts a new worker with a new interpreter. `{{name}}/worker` is the worker script, for a page that makes the worker itself.

## API

| Export | Use |
|---|---|
| `Interp.create(source?, options?)` | Makes an interpreter in a new WebAssembly instance. |
| `interp.eval(script)` | Runs a script. Returns `{ ok, result, output }`. `result` is the value, or the error message when `ok` is false. |
| `interp.stepLimit`, `interp.memLimit` | The limits of the next `eval`. |
| `interp.memorySize` | The size of the linear memory in bytes. The memory never shrinks, so this is the peak. |
| `interp.close()` | Frees the interpreter. |
| `new WorkerInterp(wasmUrl?, options?)` | An interpreter in a Web Worker. `eval` returns a promise. `reset()` makes a new interpreter. `stop()` ends the worker. |
| `compile(source?)` | Compiles the module one time, for many interpreters. |
| `wasmURL()` | The URL of the `ztcl.wasm` file of the package. |

The options are `stepLimit`, `memLimit`, and `onOutput`. `stepLimit` is the steps of each `eval`, and `null` (the default) is no limit. `memLimit` is in bytes, and the default is 2 GiB. `onOutput(text)` gets the text of `puts` when each `eval` ends.

A source is a URL, a file path in Node.js, a `Response`, bytes, or a `WebAssembly.Module`. With no source, the module is the `ztcl.wasm` file of the package.

One interpreter keeps its procs and variables from one `eval` to the next. Each `Interp` has its own instance and its own memory, so `close` and a new `Interp` give the memory back.

## Limits and capabilities

- **Steps.** Each command and each loop pass uses one step. At the limit, the script stops with the error `step limit reached`. `catch` and `try` cannot catch it. The same script stops at the same step in each browser and in Node.js.
- **Memory.** At the limit, the script stops with the error `the script used too much memory`. `catch` cannot catch it. The linear memory can grow to about twice the limit.
- **No host access.** The module has the interpreter only, with no JIT. It has no command that reaches the host: no files, sockets, `exec`, `clock`, `interp`, or event loop. `coroutine` returns an error.
- **Output.** `puts` goes into a buffer. `eval` returns the text, and `onOutput` gets it when the script ends.

Put only numbers or quoted lists into the text of a command. A value from a user can contain `[`, `$`, or `;`.

## License

BSD-2-Clause. `ztcl.wasm` contains the Zig standard library, with ports of code from musl, Go, and ARM optimized-routines. See `NOTICE` and the `licenses` folder.
