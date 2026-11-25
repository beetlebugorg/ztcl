// A small ES module over the C ABI of ztcl.wasm. It runs in a browser,
// in a Web Worker, and in Node.js.
//
// Each Interp has its own WebAssembly instance. The linear memory of an
// instance never shrinks, so close() and a new Interp give the memory
// back to the host. ztcl.wasm has no imports. The text of `puts` goes
// into a buffer, and eval() passes it to `onOutput` when the script ends.
//
// The default module is the ztcl.wasm file next to this file. Bundlers
// (Vite, webpack 5, esbuild, Rollup) find it through the
// `new URL("./ztcl.wasm", import.meta.url)` form, and a CDN serves it
// from the folder of this file.
//
// SPDX-License-Identifier: BSD-2-Clause

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// The step limit of the C ABI is a u64. This value is "no limit".
const NO_LIMIT = 0xffffffffffffffffn;

/// The URL of the ztcl.wasm file next to this file.
export function wasmURL() {
  return new URL("./ztcl.wasm", import.meta.url);
}

// The built-in modules of Node.js, through process.getBuiltinModule
// (Node.js 22.3 and later). The file has no `node:` import, so a
// bundler for the browser needs no shim.
function nodeModule(name) {
  return globalThis.process?.getBuiltinModule?.(name);
}

// True when `x` is an options object and not a source.
function isOptions(x) {
  return x != null && Object.getPrototypeOf(x) === Object.prototype;
}

/// Compiles ztcl.wasm. `source` is a URL, a Response, bytes, or a
/// WebAssembly.Module. With no source, it is the ztcl.wasm file next
/// to this file.
export async function compile(source = wasmURL()) {
  if (source instanceof WebAssembly.Module) return source;
  if (typeof source === "string" || source instanceof URL) {
    // In Node.js, a string with no scheme is a file path.
    const fs = nodeModule("node:fs/promises");
    const path = typeof source === "string" && fs && !globalThis.location && !/^[a-z][a-z0-9+.-]*:/i.test(source);
    const url = path ? nodeModule("node:url").pathToFileURL(source) : new URL(source, globalThis.location?.href);
    if (url.protocol === "file:" && fs) {
      return WebAssembly.compile(await fs.readFile(url));
    }
    source = await fetch(url);
  }
  if (typeof Response !== "undefined" && source instanceof Response) {
    if (!source.ok) throw new Error(`ztcl.wasm: HTTP ${source.status}`);
    if (WebAssembly.compileStreaming && source.headers.get("content-type") === "application/wasm") {
      return WebAssembly.compileStreaming(source);
    }
    source = await source.arrayBuffer();
  }
  return WebAssembly.compile(source);
}

export class Interp {
  /// Makes an interpreter in a new instance of `module`. `module` is a
  /// source as for compile(), and it can be left out.
  /// Options: stepLimit (steps for each eval, null for no limit),
  /// memLimit (bytes), onOutput (a function that gets the `puts` text),
  /// allow (a list of capabilities: only "file", for the files of a
  /// bundle).
  static async create(module, options = {}) {
    if (isOptions(module)) [module, options] = [undefined, module];
    const instance = await WebAssembly.instantiate(await compile(module), {});
    return new Interp(instance, options);
  }

  constructor(instance, { stepLimit = null, memLimit = null, onOutput = null, allow = [] } = {}) {
    this.x = instance.exports;
    this.h = this.x.ztcl_new();
    if (!this.h) throw new Error("ztcl_new: out of memory");
    this.stepLimit = stepLimit;
    this.onOutput = onOutput;
    if (memLimit != null) this.memLimit = memLimit;
    if (allow.length) {
      const bad = allow.filter((c) => c !== "file");
      if (bad.length || !this.x.ztcl_allow) throw new Error(`ztcl_allow: this module has no capability ${bad.join(", ") || "file"}`);
      const rc = this.x.ztcl_allow(this.h, 16);
      if (rc !== 0) throw new Error("ztcl_allow: out of memory");
    }
  }

  /// The size in bytes of the scripts and files of a bundle. Zero for a
  /// module with no bundle.
  get bundleSize() {
    return this.x.ztcl_bundle_size?.() ?? 0;
  }

  /// Runs the scripts of a bundle (`ztcl build --wasm`) in order.
  /// Returns { ok, result, output } as eval() does. On an error,
  /// `result` is "name:line: message". The step limit applies to all
  /// the scripts of the call together.
  run() {
    if (!this.bundleSize) throw new Error("the module has no bundle");
    return this._call(() => this.x.ztcl_bundle_run(this.h));
  }

  /// The memory limit in bytes. ztcl_new sets 2 GiB.
  set memLimit(bytes) {
    this.x.ztcl_set_mem_limit(this.h, bytes);
    this._mem = bytes;
  }

  get memLimit() {
    return this._mem ?? 2 ** 31;
  }

  /// The size of the linear memory in bytes. It is the peak of the
  /// instance, because the memory never shrinks.
  get memorySize() {
    return this.x.memory.buffer.byteLength;
  }

  /// Runs a script. Returns { ok, result, output }. `result` is the
  /// value of the script or the error message. The step limit applies
  /// to each call.
  eval(script) {
    const x = this.x;
    return this._call(() => {
      const bytes = encoder.encode(script);
      const ptr = x.ztcl_alloc(bytes.length || 1);
      if (!ptr) throw new Error("ztcl_alloc: out of memory");
      new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
      const rc = x.ztcl_eval(this.h, ptr, bytes.length);
      x.ztcl_free(ptr, bytes.length || 1);
      return rc;
    });
  }

  _call(f) {
    const x = this.x;
    if (!this.h) throw new Error("the interpreter is closed");
    const steps = this.stepLimit == null ? NO_LIMIT : BigInt(this.stepLimit);
    x.ztcl_set_step_limit(this.h, steps);
    const rc = f();
    const result = this._text(x.ztcl_result_ptr(this.h), x.ztcl_result_len(this.h));
    const output = this._text(x.ztcl_output_ptr(this.h), x.ztcl_output_len(this.h));
    x.ztcl_output_clear(this.h);
    if (output && this.onOutput) this.onOutput(output);
    return { ok: rc === 0, result, output };
  }

  /// Frees the interpreter. Drop the Interp after this call.
  close() {
    if (this.h) this.x.ztcl_delete(this.h);
    this.h = 0;
  }

  _text(ptr, len) {
    return decoder.decode(new Uint8Array(this.x.memory.buffer, ptr, len));
  }
}

/// Runs the scripts of a bundle in a new interpreter and closes it.
/// `module` is a source as for compile(). Options are as for
/// Interp.create. Returns { ok, result, output }.
export async function run(module, options = {}) {
  const tcl = await Interp.create(module, options);
  try {
    return tcl.run();
  } finally {
    tcl.close();
  }
}

/// Runs scripts in a Web Worker, so a long script does not block the
/// page. stop() ends the worker and the script in it. The next eval()
/// starts a new worker with a new interpreter.
export class WorkerInterp {
  /// `wasm` is the URL of ztcl.wasm, and it can be left out. Options
  /// are as for Interp.create.
  constructor(wasm, options = {}) {
    if (isOptions(wasm)) [wasm, options] = [undefined, wasm];
    const { stepLimit = null, memLimit = null, onOutput = null } = options;
    this.wasm = new URL(wasm ?? wasmURL(), globalThis.location?.href).href;
    this.stepLimit = stepLimit;
    this.memLimit = memLimit;
    this.onOutput = onOutput;
    this.worker = null;
    this.pending = new Map();
    this.next = 1;
  }

  _start() {
    // A browser starts a worker only from a URL of the same origin as
    // the page. When this file comes from a CDN, a small worker from a
    // blob URL imports the worker file. Bundlers find the second form.
    const here = new URL(import.meta.url);
    if (globalThis.location && here.origin !== globalThis.location.origin) {
      const url = new URL("ztcl-worker.mjs", here.href.replace(/[^/]*$/, ""));
      const blob = new Blob([`import ${JSON.stringify(url.href)};`], { type: "text/javascript" });
      this.worker = new Worker(URL.createObjectURL(blob), { type: "module" });
    } else {
      this.worker = new Worker(new URL("./ztcl-worker.mjs", import.meta.url), { type: "module" });
    }
    this.worker.onmessage = ({ data }) => {
      const p = this.pending.get(data.id);
      if (!p) return;
      this.pending.delete(data.id);
      if (data.error) p.reject(new Error(data.error));
      else {
        if (data.output && this.onOutput) this.onOutput(data.output);
        p.resolve({ ok: data.ok, result: data.result, output: data.output, memorySize: data.memorySize });
      }
    };
    this.worker.onerror = (e) => this._fail(e.message || "the worker failed");
    this.worker.postMessage({ init: this.wasm });
  }

  /// Runs a script in the worker. Returns a promise of
  /// { ok, result, output, memorySize }.
  eval(script) {
    if (!this.worker) this._start();
    const id = this.next++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ id, script, stepLimit: this.stepLimit, memLimit: this.memLimit });
    });
  }

  /// Makes a new interpreter in the worker for the next eval(). The
  /// old one and its memory go away.
  reset() {
    if (this.worker) this.worker.postMessage({ reset: true });
  }

  /// Ends the worker. Each pending eval() resolves with
  /// { ok: false, result: "stopped" }. The variables and procs go away.
  stop() {
    if (!this.worker) return;
    this.worker.terminate();
    this.worker = null;
    for (const p of this.pending.values()) p.resolve({ ok: false, result: "stopped", output: "" });
    this.pending.clear();
  }

  _fail(message) {
    this.worker?.terminate();
    this.worker = null;
    for (const p of this.pending.values()) p.reject(new Error(message));
    this.pending.clear();
  }
}
