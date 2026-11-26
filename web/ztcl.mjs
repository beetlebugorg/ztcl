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

// The compute limit of the C ABI is a u64. This value is "no limit".
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

// The orders of the columns of ztcl_point_run (`point.Field` and `point.Out`).
const POINT_FIELDS = ["x", "y", "z", "width", "height", "speed", "flow", "feature", "layer", "path", "dist"];
const POINT_OUTS = ["offset", "move_x", "move_y", "width", "flow", "speed", "skip"];

export class Interp {
  /// Makes an interpreter in a new instance of `module`. `module` is a
  /// source as for compile(), and it can be left out.
  /// Options: computeLimit (compute units for each eval, null for no limit),
  /// memLimit (bytes), onOutput (a function that gets the `puts` text),
  /// allow (a list of capabilities: only "file", for the files of a
  /// bundle), and point (true adds `point proc` and the output commands).
  static async create(module, options = {}) {
    if (isOptions(module)) [module, options] = [undefined, module];
    const mod = await compile(module);
    // `ztcl-host.wasm` imports the module `ztcl_host`. Its calls go to
    // the Interp, which exists after the instance.
    let self = null;
    const imports = {};
    if (WebAssembly.Module.imports(mod).some((i) => i.module === "ztcl_host")) {
      imports.ztcl_host = {
        output: (ptr, len) => self._live(ptr, len),
        dom: (op, h, a, aLen, b, bLen) => self._dom(op, h, a, aLen, b, bLen),
        now_ms: () => self._now(),
        zone: (ptr, len) => self._zone(ptr, len),
      };
    }
    // A build with `-Dcext-wasm` imports `ztcl_cext.call` for the commands of
    // the C packages of loadPackage().
    if (WebAssembly.Module.imports(mod).some((i) => i.module === "ztcl_cext")) {
      imports.ztcl_cext = { call: (pkg, id, argc, argv) => self._cextCall(pkg, id, argc, argv) };
    }
    const instance = await WebAssembly.instantiate(mod, imports);
    self = new Interp(instance, options);
    return self;
  }

  constructor(instance, { computeLimit = null, memLimit = null, onOutput = null, allow = [], point = false, domRoot = null, now = null, zone = null } = {}) {
    this.x = instance.exports;
    this.h = this.x.ztcl_new();
    if (!this.h) throw new Error("ztcl_new: out of memory");
    if (point && !this.x.ztcl_point_install) throw new Error("point: this module has no point procs (use ztcl-simd.wasm)");
    if (point && !this.x.ztcl_point_install(this.h)) throw new Error("ztcl_point_install: out of memory");
    this.computeLimit = computeLimit;
    this.onOutput = onOutput;
    if (memLimit != null) this.memLimit = memLimit;
    // `clock` reads the time of the host (`now`, milliseconds since 1970,
    // Date.now by default) and the TZif bytes of a zone (`zone(name)`,
    // a Uint8Array or null).
    this._now = now ?? (() => Date.now());
    this._zoneOf = zone;
    if (allow.includes("clock")) {
      if (!this.x.ztcl_clock_allow) throw new Error("clock: this module has no clock (use ztcl-host.wasm)");
      if (this.x.ztcl_clock_allow(this.h) !== 0) throw new Error("ztcl_clock_allow: out of memory");
      allow = allow.filter((c) => c !== "clock");
    }
    if (allow.includes("dom")) {
      if (!this.x.ztcl_dom_allow) throw new Error("dom: this module has no DOM access (use ztcl-host.wasm)");
      this._domRoot = domRoot ?? globalThis.document?.body;
      if (!this._domRoot) throw new Error("dom: no domRoot and no document.body");
      this._handles = new Map();
      this._ids = new Map();
      if (this.x.ztcl_dom_allow(this.h) !== 0) throw new Error("ztcl_dom_allow: out of memory");
      allow = allow.filter((c) => c !== "dom");
    }
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
  /// `result` is "name:line: message". The compute limit applies to all
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
  /// value of the script or the error message. The compute limit applies
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

  /// The point proc `name` of a script, after `point: true`: its
  /// `outputs` (the names of the columns that it writes) and its
  /// run({ n, seed, inputs, feature, outputs }) runs the proc over n
  /// points: `inputs` maps field names (x, y, z, width, height, speed,
  /// flow, layer, path, dist) to Float64Array columns, `feature` is a
  /// Uint8Array of feature numbers, and `outputs` maps output names
  /// (offset, move_x, move_y, width, flow, speed, skip) to Float64Array
  /// columns with the start values. run() writes the new values into
  /// `outputs` and returns the compute units. The compute limit applies
  /// to each call.
  pointProc(name) {
    const x = this.x;
    const bytes = encoder.encode(name);
    const ptr = x.ztcl_alloc(bytes.length || 1);
    new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
    const id = x.ztcl_point_compile(this.h, ptr, bytes.length);
    x.ztcl_free(ptr, bytes.length || 1);
    if (!id) throw new Error(this._text(x.ztcl_result_ptr(this.h), x.ztcl_result_len(this.h)));
    const mask = x.ztcl_point_outputs(this.h, id);
    return { outputs: POINT_OUTS.filter((_, k) => mask & (1 << k)), run: (points) => this._pointRun(id, points) };
  }

  _pointRun(id, { n, seed = 1, inputs = {}, feature = null, outputs = {} }) {
    const x = this.x;
    const size = (POINT_FIELDS.length + POINT_OUTS.length) * n * 8 + n;
    // ztcl_point_run reads f64 columns, so the block starts on 8 bytes.
    const raw = x.ztcl_alloc(size + 8);
    if (!raw) throw new Error("ztcl_alloc: out of memory");
    const ptr = (raw + 7) & ~7;
    try {
      let inMask = 0;
      let outMask = 0;
      const f64 = new Float64Array(x.memory.buffer, ptr, (POINT_FIELDS.length + POINT_OUTS.length) * n);
      POINT_FIELDS.forEach((f, k) => {
        if (f === "feature") {
          if (feature) {
            new Uint8Array(x.memory.buffer, ptr + (POINT_FIELDS.length + POINT_OUTS.length) * n * 8, n).set(feature.subarray(0, n));
            inMask |= 1 << k;
          }
        } else if (inputs[f]) {
          f64.set(inputs[f].subarray(0, n), k * n);
          inMask |= 1 << k;
        }
      });
      POINT_OUTS.forEach((o, k) => {
        if (outputs[o]) {
          f64.set(outputs[o].subarray(0, n), (POINT_FIELDS.length + k) * n);
          outMask |= 1 << k;
        }
      });
      x.ztcl_set_compute_limit(this.h, this.computeLimit == null ? NO_LIMIT : BigInt(this.computeLimit));
      const units = x.ztcl_point_run(this.h, id, ptr, n, seed, inMask, outMask);
      if (units === -1n) throw new Error("compute limit reached");
      if (units < 0n) throw new Error(`ztcl_point_run: error ${units}`);
      const out = new Float64Array(x.memory.buffer, ptr, (POINT_FIELDS.length + POINT_OUTS.length) * n);
      POINT_OUTS.forEach((o, k) => {
        if (outputs[o]) outputs[o].set(out.subarray((POINT_FIELDS.length + k) * n, (POINT_FIELDS.length + k + 1) * n));
      });
      return Number(units);
    } finally {
      x.ztcl_free(raw, size + 8);
    }
  }

  /// The text of one `puts` of `ztcl-host.wasm`, at the time of the call.
  _live(ptr, len) {
    const text = this._text(ptr, len);
    this._liveOut += text;
    if (this.onOutput) this.onOutput(text);
  }

  // The import `ztcl_host.zone`: the TZif bytes of a zone name.
  _zone(ptr, len) {
    const bytes = this._zoneOf?.(this._text(ptr, len));
    if (!bytes || !bytes.length) return 1;
    const p = this.x.ztcl_alloc(bytes.length);
    if (!p) return 1;
    new Uint8Array(this.x.memory.buffer, p, bytes.length).set(bytes);
    const slot = new Uint32Array(this.x.memory.buffer, this.x.ztcl_zone_reply(), 2);
    slot[0] = p;
    slot[1] = bytes.length;
    return 0;
  }

  // The import `ztcl_host.dom` (src/wasmdom.zig). A handle is an index
  // in a table, and 0 is the root. Each element must be the root or below
  // it. The reply text goes into the memory of the module.
  _dom(op, h, a, aLen, b, bLen) {
    const root = this._domRoot;
    const reply = (text) => {
      const bytes = encoder.encode(text);
      if (!bytes.length) return;
      const p = this.x.ztcl_alloc(bytes.length);
      new Uint8Array(this.x.memory.buffer, p, bytes.length).set(bytes);
      const slot = new Uint32Array(this.x.memory.buffer, this.x.ztcl_dom_reply.value, 2);
      slot[0] = p;
      slot[1] = bytes.length;
    };
    const fail = (msg) => {
      reply(msg);
      return -1;
    };
    let el = root;
    if (h !== 0) {
      el = this._handles.get(h);
      if (!el || !(el === root || root.contains(el))) return fail(`invalid DOM handle "dom${h}"`);
    }
    const handle = (e) => {
      let id = this._ids.get(e);
      if (!id) {
        id = this._handles.size + 1;
        this._handles.set(id, e);
        this._ids.set(e, id);
      }
      return id;
    };
    const sa = this._text(a, aLen);
    const sb = this._text(b, bLen);
    try {
      switch (op) {
        case 1: {
          const e = el.querySelector(sa);
          return e ? handle(e) : 0;
        }
        case 2:
          reply(Array.from(el.querySelectorAll(sa), (e) => handle(e)).join(" "));
          return 0;
        case 3:
          reply(el.textContent ?? "");
          return 0;
        case 4:
          el.textContent = sa;
          return 0;
        case 5:
          reply(el.getAttribute(sa) ?? "");
          return 0;
        case 6:
          el.setAttribute(sa, sb);
          return 0;
      }
      return fail(`dom: unknown operation ${op}`);
    } catch (e) {
      return fail(String(e.message || e));
    }
  }

  _call(f) {
    const x = this.x;
    if (!this.h) throw new Error("the interpreter is closed");
    const units = this.computeLimit == null ? NO_LIMIT : BigInt(this.computeLimit);
    x.ztcl_set_compute_limit(this.h, units);
    this._liveOut = "";
    const rc = f();
    const result = this._text(x.ztcl_result_ptr(this.h), x.ztcl_result_len(this.h));
    const kept = this._text(x.ztcl_output_ptr(this.h), x.ztcl_output_len(this.h));
    x.ztcl_output_clear(this.h);
    if (kept && this.onOutput) this.onOutput(kept);
    return { ok: rc === 0, result, output: this._liveOut + kept };
  }

  /// Frees the interpreter. Drop the Interp after this call.
  /// Loads a C package that `zig cc -target wasm32-wasi` built with
  /// libztclstubs.a (docs/dev/cext-tasks/04w-wasm-bridge.md), and runs
  /// its init function, for example "Sqlite3_Init". The module needs a
  /// ztcl library built with `-Dcext-wasm`. `wasi` is the import object of
  /// `wasi_snapshot_preview1`, for example the wasiImport of a WASI of
  /// Node.js. With no `wasi`, the package gets no files: each call of
  /// WASI gives ENOSYS, except the clock and random bytes.
  async loadPackage(source, { init, wasi = null } = {}) {
    if (!this.x.ztcl_cext_command) throw new Error("loadPackage: this module has no C packages (build with -Dcext-wasm)");
    if (!init) throw new Error("loadPackage: no init function");
    const mod = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    const index = (this._pkgs ??= []).length;
    const pkg = { x: null, index };
    const imports = { ztcl: this._cextImports(pkg), wasi_snapshot_preview1: wasi ?? noWasi(pkg) };
    const instance = await WebAssembly.instantiate(mod, imports);
    pkg.x = instance.exports;
    pkg.side = this._side(pkg.x);
    if (wasi?.initialize) wasi.initialize(instance);
    else pkg.x._initialize?.();
    this._pkgs.push(pkg);
    const ip = pkg.x.ztcl_cext_interp(this.h);
    const rc = pkg.x[init](ip);
    if (rc !== 0) {
      const r = new Uint32Array(pkg.x.memory.buffer, pkg.x.ztcl_cext_result(ip), 4);
      throw new Error(`${init}: ${decoder.decode(new Uint8Array(pkg.x.memory.buffer, r[2], r[1]))}`);
    }
  }

  // The views of the memory of a side of the bridge (`side.x` is the
  // instance). A view is made again after the memory grows. The reply
  // record has a fixed address, and the exchange buffer moves only when
  // it grows, so the glue keeps both.
  _side(x) {
    const side = { x, buf: null, u8: null, u32: null, reply: x.ztcl_cext_reply() >>> 2, xb: 0, xcap: -1, args: 0, acap: -1 };
    side.view = () => {
      if (side.buf !== x.memory.buffer) {
        side.buf = x.memory.buffer;
        side.u8 = new Uint8Array(side.buf);
        side.u32 = new Uint32Array(side.buf);
      }
      return side;
    };
    // The address of an exchange buffer of at least `len` bytes.
    side.xbuf = (len) => {
      if (len > side.xcap) {
        side.xb = x.ztcl_cext_buf(Math.max(len, 2 * side.xcap, 256));
        side.xcap = Math.max(len, 2 * side.xcap, 256);
      }
      return side.xb;
    };
    return side;
  }

  // Copies the reply record of `from` to the reply of `to`. Text goes
  // into the exchange buffer of `to`.
  _cextReply(from, to) {
    const f = from.view().u32, r = from.reply;
    const kind = f[r], len = f[r + 1];
    if (kind === 0) {
      const p = f[r + 2];
      const dst = to.xbuf(len);
      const t = to.view();
      t.u8.set(from.u8.subarray(p, p + len), dst);
      const tr = to.reply;
      t.u32[tr] = 0; t.u32[tr + 1] = len; t.u32[tr + 2] = dst; t.u32[tr + 3] = 0;
      return;
    }
    const t = to.view().u32, tr = to.reply;
    t[tr] = kind; t[tr + 1] = len; t[tr + 2] = f[r + 2]; t[tr + 3] = f[r + 3];
  }

  // Copies `len` bytes at `ptr` of the package into the exchange buffer
  // of ztcl, with `extra` bytes of room after them.
  _toZtcl(p, ptr, len, extra = 0) {
    const z = this._zside;
    const zb = z.xbuf(len + extra);
    z.view().u8.set(p.view().u8.subarray(ptr, ptr + len), zb);
    return zb;
  }

  _cextImports(pkg) {
    const z = this.x;
    this._zside ??= this._side(z);
    const zs = this._zside;
    return {
      cmd_create: (h, id, ptr, len) => z.ztcl_cext_command(h, pkg.index, id, this._toZtcl(pkg.side, ptr, len), len),
      cmd_delete: (h, ptr, len) => {
        const rc = z.ztcl_cext_delete(h, this._toZtcl(pkg.side, ptr, len), len);
        if (rc !== 0) this._cextReply(zs, pkg.side);
        return rc;
      },
      eval: (h, ptr, len, flags) => {
        const rc = z.ztcl_cext_eval(h, this._toZtcl(pkg.side, ptr, len), len, flags);
        this._cextReply(zs, pkg.side);
        return rc;
      },
      var_get: (h, ptr, len, flags) => {
        const rc = z.ztcl_cext_var_get(h, this._toZtcl(pkg.side, ptr, len), len, flags);
        this._cextReply(zs, pkg.side);
        return rc;
      },
      var_set: (h, ptr, len, arg, flags) => {
        const ps = pkg.side.view();
        const a = arg >>> 2;
        const kind = ps.u32[a], vlen = ps.u32[a + 1], lo = ps.u32[a + 2], hi = ps.u32[a + 3];
        const extra = kind === 0 ? vlen : 0;
        const zb = this._toZtcl(ps, ptr, len, extra);
        const zv = zs.view();
        if (extra) zv.u8.set(ps.u8.subarray(lo, lo + vlen), zb + len);
        const zr = zs.reply;
        zv.u32[zr] = kind; zv.u32[zr + 1] = vlen; zv.u32[zr + 2] = kind === 0 ? zb + len : lo; zv.u32[zr + 3] = kind === 0 ? 0 : hi;
        const rc = z.ztcl_cext_var_set(h, zb, len, zr << 2, flags);
        if (rc !== 0) this._cextReply(zs, ps);
        return rc;
      },
      pkg_provide: () => 0,
    };
  }

  // The import `ztcl_cext.call`: copies the arguments into the package
  // and runs the command there.
  _cextCall(pkgIndex, id, argc, argv) {
    const ps = this._pkgs[pkgIndex].side;
    const zs = this._zside.view();
    const src = zs.u32, s0 = argv >>> 2;
    let total = 0;
    for (let i = 0; i < argc; i++) if (src[s0 + i * 4] === 0) total += src[s0 + i * 4 + 1];
    let off = ps.xbuf(total);
    if (argc > ps.acap) {
      ps.acap = Math.max(argc, 16);
      ps.args = ps.x.ztcl_cext_args(ps.acap);
    }
    const p = ps.view();
    const dst = p.u32, d0 = ps.args >>> 2;
    const zu8 = zs.u8, pu8 = p.u8;
    for (let i = 0; i < argc; i++) {
      const si = s0 + i * 4, di = d0 + i * 4;
      const k = src[si], len = src[si + 1];
      dst[di] = k; dst[di + 1] = len;
      if (k === 0) {
        const a = src[si + 2];
        if (len < 16) for (let j = 0; j < len; j++) pu8[off + j] = zu8[a + j];
        else pu8.set(zu8.subarray(a, a + len), off);
        dst[di + 2] = off; dst[di + 3] = 0;
        off += len;
      } else {
        dst[di + 2] = src[si + 2]; dst[di + 3] = src[si + 3];
      }
    }
    const rc = ps.x.ztcl_cext_dispatch(id, argc);
    this._cextReply(ps, this._zside);
    return rc;
  }

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
    const { computeLimit = null, memLimit = null, onOutput = null } = options;
    this.wasm = new URL(wasm ?? wasmURL(), globalThis.location?.href).href;
    this.computeLimit = computeLimit;
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
      this.worker.postMessage({ id, script, computeLimit: this.computeLimit, memLimit: this.memLimit });
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

// The WASI imports of a package with no files: ENOSYS (52) for each
// call, except the clock, random bytes, and empty arguments and
// environment. `pkg.x` is the instance after instantiate().
function noWasi(pkg) {
  const mem = () => pkg.x.memory.buffer;
  const own = {
    clock_time_get: (id, prec, out) => {
      new DataView(mem()).setBigUint64(out, BigInt(Date.now()) * 1000000n, true);
      return 0;
    },
    random_get: (ptr, len) => {
      globalThis.crypto.getRandomValues(new Uint8Array(mem(), ptr, len));
      return 0;
    },
    args_sizes_get: (argc, size) => { new Uint32Array(mem(), argc, 1)[0] = 0; new Uint32Array(mem(), size, 1)[0] = 0; return 0; },
    environ_sizes_get: (n, size) => { new Uint32Array(mem(), n, 1)[0] = 0; new Uint32Array(mem(), size, 1)[0] = 0; return 0; },
    proc_exit: (code) => { throw new Error(`the package called proc_exit(${code})`); },
  };
  return new Proxy({}, { get: (_, name) => own[name] ?? (() => 52) });
}
