// A small ES module over the C ABI of ztcl.wasm. It runs in a browser,
// in a Web Worker, and in Node.js.
//
// Each Interp has its own WebAssembly instance. The linear memory of an
// instance never shrinks, so close() and a new Interp give the memory
// back to the host. ztcl.wasm has no imports. The text of `puts` goes
// into a buffer, and eval() passes it to `onOutput` when the script ends.
//
// SPDX-License-Identifier: BSD-2-Clause

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// The step limit of the C ABI is a u64. This value is "no limit".
const NO_LIMIT = 0xffffffffffffffffn;

/// Compiles ztcl.wasm. `source` is a URL, a Response, bytes, or a
/// WebAssembly.Module.
export async function compile(source) {
  if (source instanceof WebAssembly.Module) return source;
  if (typeof source === "string" || source instanceof URL) {
    // In Node.js, a string with no scheme is a file path.
    const path = typeof source === "string" && !globalThis.location && !/^[a-z][a-z0-9+.-]*:/i.test(source);
    const url = path ? new URL(`file://${(await import("node:path")).resolve(source)}`) : new URL(source, globalThis.location?.href);
    if (url.protocol === "file:") {
      const fs = await import("node:fs/promises");
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
  /// Makes an interpreter in a new instance of `module`.
  /// Options: stepLimit (steps for each eval, null for no limit),
  /// memLimit (bytes), onOutput (a function that gets the `puts` text).
  static async create(module, options = {}) {
    const instance = await WebAssembly.instantiate(await compile(module), {});
    return new Interp(instance, options);
  }

  constructor(instance, { stepLimit = null, memLimit = null, onOutput = null } = {}) {
    this.x = instance.exports;
    this.h = this.x.ztcl_new();
    if (!this.h) throw new Error("ztcl_new: out of memory");
    this.stepLimit = stepLimit;
    this.onOutput = onOutput;
    if (memLimit != null) this.memLimit = memLimit;
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
    if (!this.h) throw new Error("the interpreter is closed");
    const steps = this.stepLimit == null ? NO_LIMIT : BigInt(this.stepLimit);
    x.ztcl_set_step_limit(this.h, steps);
    const bytes = encoder.encode(script);
    const ptr = x.ztcl_alloc(bytes.length || 1);
    if (!ptr) throw new Error("ztcl_alloc: out of memory");
    new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
    const rc = x.ztcl_eval(this.h, ptr, bytes.length);
    x.ztcl_free(ptr, bytes.length || 1);
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

/// Runs scripts in a Web Worker, so a long script does not block the
/// page. stop() ends the worker and the script in it. The next eval()
/// starts a new worker with a new interpreter.
export class WorkerInterp {
  /// `wasm` is the URL of ztcl.wasm. Options are as for Interp.create.
  constructor(wasm, { stepLimit = null, memLimit = null, onOutput = null } = {}) {
    this.wasm = new URL(wasm, globalThis.location?.href).href;
    this.stepLimit = stepLimit;
    this.memLimit = memLimit;
    this.onOutput = onOutput;
    this.worker = null;
    this.pending = new Map();
    this.next = 1;
  }

  _start() {
    this.worker = new Worker(new URL("./ztcl-worker.mjs", import.meta.url), { type: "module" });
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
