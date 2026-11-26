// ztcl with the capability `thread` in a browser and in Node.js.
//
//   import { ThreadInterp } from "./ztcl-threads.mjs";
//   const t = await ThreadInterp.create({ allow: ["thread"] });
//   const r = await t.eval("thread::send [thread::create] {expr 6 * 7}");
//   t.close();
//
// Each ztcl thread runs in a worker (web/ztcl-thread-worker.mjs), the
// main interpreter too. This module is the host: it makes the workers
// and routes their messages. It has two modes:
//
// - shared: a cross-origin isolated page, or Node.js. The workers use
//   ztcl-threads.wasm on one shared memory, and each command works.
// - async: a page without cross-origin isolation. The workers use
//   ztcl-async.wasm, each with its own memory. Only the commands that
//   do not wait work. A command that waits gives an error that names
//   the headers COOP and COEP.
// SPDX-License-Identifier: BSD-2-Clause

import { compile } from "./ztcl.mjs";

const node = typeof process !== "undefined" && !!process.versions?.node && typeof window === "undefined";

/// The capability bits of `Capability` in src/interp.zig.
const CAPS = { package: 1, interp: 2, clock: 4, event: 32, thread: 2048 };

/// The sizes of the shared memory in pages of 64 KiB. build.zig sets the
/// same sizes for ztcl-threads.wasm.
const INITIAL_PAGES = 512;
/// The shared mode keeps at most this many workers with no thread.
const MAX_IDLE = 64;
const MAX_PAGES = 32768;

// A string in the byte form of src/webasync.zig.
function stringBytes(text) {
  const t = new TextEncoder().encode(text);
  const b = new Uint8Array(5 + t.length);
  b[0] = 0x73; // "s"
  new DataView(b.buffer).setUint32(1, t.length, true);
  b.set(t, 5);
  return b;
}

export function threadsURL() {
  return new URL("./ztcl-threads.wasm", import.meta.url);
}

export function asyncURL() {
  return new URL("./ztcl-async.wasm", import.meta.url);
}

/// True when the host can use the shared mode.
export function isolated() {
  return node || globalThis.crossOriginIsolated === true;
}

const NodeWorker = node ? (await import("node:worker_threads")).Worker : null;

function makeWorker() {
  const url = new URL("./ztcl-thread-worker.mjs", import.meta.url);
  if (node) {
    const w = new NodeWorker(url);
    return { post: (m) => w.postMessage(m), on: (f) => w.on("message", f), onError: (f) => w.on("error", f), stop: () => w.terminate() };
  }
  let w;
  if (globalThis.location && url.origin !== globalThis.location.origin) {
    // A worker script must have the origin of the page.
    const blob = new Blob([`import ${JSON.stringify(url.href)};`], { type: "text/javascript" });
    w = new Worker(URL.createObjectURL(blob), { type: "module" });
  } else {
    w = new Worker(url, { type: "module" });
  }
  return { post: (m) => w.postMessage(m), on: (f) => (w.onmessage = ({ data }) => f(data)), onError: (f) => (w.onerror = (e) => f(e)), stop: () => w.terminate() };
}

export class ThreadInterp {
  /// Options: `mode` ("auto", "shared", or "async"), `wasm` (the URL of
  /// ztcl-threads.wasm), `asyncWasm` (the URL of ztcl-async.wasm),
  /// `allow` (capability names: "thread", "event", "clock", "package",
  /// "interp"), `limits` (maxThreads, computeLimit, memLimit, totalCompute,
  /// totalMem, maxQueue), `computeLimit`, `memLimit`, and `onOutput`.
  static async create(options = {}) {
    const t = new ThreadInterp(options);
    await t._start();
    return t;
  }

  constructor({ mode = "auto", wasm, asyncWasm, allow = ["thread"], limits = {}, computeLimit = null, memLimit = null, onOutput = null } = {}) {
    if (mode === "auto") mode = isolated() ? "shared" : "async";
    if (mode === "shared" && !isolated()) throw new Error("the shared mode needs a cross-origin isolated page (COOP and COEP headers)");
    this.mode = mode;
    this.wasm = mode === "shared" ? (wasm ?? threadsURL()) : (asyncWasm ?? asyncURL());
    this.caps = 0;
    for (const c of allow) {
      if (!(c in CAPS)) throw new Error(`unknown capability: ${c}`);
      this.caps |= CAPS[c];
    }
    this.limits = limits;
    this.computeLimit = computeLimit;
    this.memLimit = memLimit;
    this.onOutput = onOutput;
    this.workers = new Map(); // id to worker; the main interpreter is 1
    this.idle = []; // the shared mode: the workers with no thread
    this.pending = new Map();
    this.next = 1;
    this.failure = null;
  }

  async _start() {
    this.module = await compile(this.wasm);
    if (this.mode === "shared") this.memory = new WebAssembly.Memory({ initial: INITIAL_PAGES, maximum: MAX_PAGES, shared: true });
    this.main = await this._worker(1, { role: "main", memLimit: this.memLimit });
  }

  // Makes a worker and waits for its `ready`. A message to the worker
  // can go before the `ready`: the worker runs its messages in order.
  async _worker(id, init) {
    const w = makeWorker();
    this.workers.set(id, w);
    // A failure before the `ready` rejects the start.
    const ready = new Promise((resolve, reject) => {
      w.ready = resolve;
      w.failStart = reject;
    });
    w.on((m) => this._message(id, w, m));
    w.onError((e) => {
      w.failStart(new Error(e?.message ?? String(e)));
      this._fail(e?.message ?? String(e));
    });
    const base = { module: this.module, id, caps: this.caps, limits: this.limits };
    if (this.memory) base.memory = this.memory;
    w.post({ init: { ...base, ...init } });
    await ready;
    return w;
  }

  _message(id, w, m) {
    if (m.ready) return w.ready();
    if (m.output) this.onOutput?.(m.output);
    if (m.fatal) {
      w.failStart(new Error(m.fatal));
      return this._fail(m.fatal);
    }
    if (m.spawn != null) {
      // The shared mode: a new thread. Its record in the shared memory
      // has the rest. An idle worker runs it when one exists.
      const idle = this.idle.pop();
      if (idle) idle.post({ run: m.spawn });
      else this._worker(`w${this.next++}`, { role: "thread", arg: m.spawn });
      return;
    }
    if (m.idle) {
      // The shared mode: the thread of the worker ended.
      if (this.idle.length < MAX_IDLE) this.idle.push(w);
      else {
        w.stop();
        this.workers.delete(id);
      }
      return;
    }
    if (m.exit) {
      w.stop();
      this.workers.delete(id);
      if (this.mode === "async" && id !== 1) this.main?.post({ gone: id });
      return;
    }
    if (m.create) {
      // The async mode: the main interpreter made a thread.
      const { id: tid, script } = m.create;
      this._worker(tid, { role: "thread", script, computeLimit: this.limits.computeLimit ?? this.computeLimit, memLimit: this.limits.memLimit });
      return;
    }
    if (m.send) {
      const { to, token, script } = m.send;
      const targets = to === 0 ? [...this.workers.keys()].filter((k) => k !== id) : [to];
      for (const k of targets) {
        const t = this.workers.get(k);
        const msg = { deliver: { from: id, token, script } };
        if (!t) {
          if (token) w.post({ reply: { token, code: 1, bytes: stringBytes("target thread died") } });
        } else t.post(msg);
      }
      return;
    }
    if (m.reply) {
      this.workers.get(m.reply.to)?.post({ reply: m.reply });
      return;
    }
    if (m.id != null) {
      const p = this.pending.get(m.id);
      if (!p) return;
      this.pending.delete(m.id);
      if (m.error) p.reject(new Error(m.error));
      else p.resolve({ ok: m.ok, result: m.result, output: m.output });
    }
  }

  /// Runs a script in the main interpreter.
  eval(script) {
    if (this.failure) return Promise.reject(new Error(this.failure));
    if (!this.main) return Promise.reject(new Error("the interpreter is closed"));
    const id = this.next++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.main.post({ eval: id, script, computeLimit: this.computeLimit });
    });
  }

  /// Stops each worker.
  close() {
    for (const w of this.workers.values()) w.stop?.();
    this.workers.clear();
    this.idle = [];
    this.main = null;
    for (const p of this.pending.values()) p.resolve({ ok: false, result: "stopped", output: "" });
    this.pending.clear();
  }

  _fail(message) {
    this.failure = message;
    for (const p of this.pending.values()) p.reject(new Error(message));
    this.pending.clear();
  }
}
