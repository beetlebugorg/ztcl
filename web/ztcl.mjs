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
  /// allow (a list of capabilities: "file" for the files of a bundle;
  /// "clock", "event", "dom", and "dom-html" with ztcl-host.wasm),
  /// onEvents (a function that gets the result of each run of the
  /// events of a timer), point (true adds `point proc` and the output commands), and
  /// packages (a function of a file name for the `load` command of the C
  /// packages, in a build with `-Dcext-wasm`: see _addLoad), and tcl
  /// (the Tcl release that the commands follow: "8.6", the default, or
  /// "9.1").
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
      imports.ztcl_cext = { call: (pkg, id, argc, argv, prec) => self._cextCall(pkg, id, argc, argv, prec) };
    }
    const instance = await WebAssembly.instantiate(mod, imports);
    self = new Interp(instance, options);
    return self;
  }

  constructor(instance, { computeLimit = null, memLimit = null, onOutput = null, allow = [], point = false, domRoot = null, now = null, zone = null, packages = null, tcl = "8.6", onEvents = null } = {}) {
    this.x = instance.exports;
    this.h = this.x.ztcl_new();
    if (!this.h) throw new Error("ztcl_new: out of memory");
    if (tcl !== "8.6") {
      const t = encoder.encode(String(tcl));
      const p = this.x.ztcl_alloc(t.length || 1);
      if (!p) throw new Error("ztcl_alloc: out of memory");
      new Uint8Array(this.x.memory.buffer, p, t.length).set(t);
      const rc = this.x.ztcl_set_tcl_version(this.h, p, t.length);
      this.x.ztcl_free(p, t.length || 1);
      if (rc === 1) throw new Error(`tcl: bad Tcl version "${tcl}": must be 8.6 or 9.1`);
      if (rc !== 0) throw new Error("ztcl_set_tcl_version: out of memory");
    }
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
    // `event` (`after`, `after idle`, `update`) in ztcl-host.wasm. The
    // events run from setTimeout on the clock `now`, and `onEvents` gets
    // the { ok, result, output } of each run.
    this.onEvents = onEvents;
    this._timer = null;
    if (allow.includes("event")) {
      if (!this.x.ztcl_events_allow) throw new Error("event: this module has no event loop (use ztcl-host.wasm)");
      if (this.x.ztcl_events_allow(this.h) !== 0) throw new Error("ztcl_events_allow: out of memory");
      this._events = true;
      allow = allow.filter((c) => c !== "event");
    }
    if (allow.includes("dom")) {
      if (!this.x.ztcl_dom_allow) throw new Error("dom: this module has no DOM access (use ztcl-host.wasm)");
      this._domRoot = domRoot ?? globalThis.document?.body;
      if (!this._domRoot) throw new Error("dom: no domRoot and no document.body");
      this._handles = new Map();
      this._ids = new Map();
      this._nextHandle = 1;
      // The elements of `dom create`. A tree of them that is not in the
      // document yet is in scope, so a script can build it before
      // `dom append`.
      this._made = new WeakSet();
      this._domHtml = allow.includes("dom-html");
      allow = allow.filter((c) => c !== "dom-html");
      if (this.x.ztcl_dom_allow(this.h) !== 0) throw new Error("ztcl_dom_allow: out of memory");
      allow = allow.filter((c) => c !== "dom");
    }
    if (allow.length) {
      const bad = allow.filter((c) => c !== "file");
      if (bad.length || !this.x.ztcl_allow) throw new Error(`ztcl_allow: this module has no capability ${bad.join(", ") || "file"}`);
      const rc = this.x.ztcl_allow(this.h, 16);
      if (rc !== 0) throw new Error("ztcl_allow: out of memory");
    }
    if (packages) this._addLoad(packages);
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
    if (this._depth) return this._evalIn(script);
    const r = this._call(() => {
      const bytes = encoder.encode(script);
      const ptr = x.ztcl_alloc(bytes.length || 1);
      if (!ptr) throw new Error("ztcl_alloc: out of memory");
      new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
      const rc = x.ztcl_eval(this.h, ptr, bytes.length);
      x.ztcl_free(ptr, bytes.length || 1);
      return rc;
    });
    if (this._events) this._schedule();
    return r;
  }

  /// Runs the events that are due at `now` (milliseconds on the clock of
  /// the option `now`), after `allow: ["event"]`. Returns { ok, result,
  /// output }. A timer of setTimeout calls it for each due event, so a
  /// page calls it only to run the events at a time of its own.
  runEvents(now = this._now()) {
    if (!this._events) throw new Error("runEvents: no allow: [\"event\"]");
    const r = this._call(() => this.x.ztcl_run_events(this.h, now));
    this._schedule();
    return r;
  }

  // Sets the timer for the next event, or clears it when no event exists.
  _schedule() {
    if (this._timer !== null) clearTimeout(this._timer);
    this._timer = null;
    if (!this.h) return;
    const left = this.x.ztcl_next_event(this.h, this._now());
    if (left < 0) return;
    this._timer = setTimeout(() => {
      this._timer = null;
      const r = this.runEvents();
      if (this.onEvents) this.onEvents(r);
    }, left);
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
    // An element is in scope when it is the root or below it, or when
    // the top of its tree is an element of `dom create` that is not in
    // the document.
    const inScope = (e) => {
      if (e === root || root.contains(e)) return true;
      let top = e;
      while (top.parentNode) top = top.parentNode;
      return this._made.has(top) && !top.isConnected;
    };
    let el = root;
    if (h !== 0) {
      el = this._handles.get(h);
      if (!el || !inScope(el)) return fail(`invalid DOM handle "dom${h}"`);
    }
    const handle = (e) => {
      let id = this._ids.get(e);
      if (!id) {
        id = this._nextHandle++;
        this._handles.set(id, e);
        this._ids.set(e, id);
      }
      return id;
    };
    const sa = this._text(a, aLen);
    const sb = this._text(b, bLen);
    // No command runs JavaScript: no element that loads or runs code,
    // no event attribute, and no `javascript:` URL.
    const badTags = ["script", "iframe", "frame", "frameset", "object", "embed", "base", "link", "meta", "template"];
    const badAttr = (n, v) => {
      n = n.toLowerCase();
      if (n.startsWith("on") || n === "srcdoc" || n === "is") return true;
      const url = String(v).replace(/[\s\x00-\x1f]/g, "").toLowerCase();
      return url.startsWith("javascript:") || url.startsWith("vbscript:");
    };
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
          if (badAttr(sa, sb)) return fail(`dom attr: the attribute "${sa}" can run code`);
          el.setAttribute(sa, sb);
          return 0;
        case 7: // class: `sa` is add, remove, toggle, or has.
          if (sa === "add") el.classList.add(sb);
          else if (sa === "remove") el.classList.remove(sb);
          else if (sa === "toggle") return el.classList.toggle(sb) ? 1 : 0;
          else return el.classList.contains(sb) ? 1 : 0;
          return 0;
        case 8:
          reply(el.style.getPropertyValue(sa));
          return 0;
        case 9:
          el.style.setProperty(sa, sb);
          return 0;
        case 10:
          reply(String(el.type === "checkbox" || el.type === "radio" ? (el.checked ? 1 : 0) : (el.value ?? "")));
          return 0;
        case 11:
          if (el.type === "checkbox" || el.type === "radio") el.checked = sa !== "" && sa !== "0";
          else el.value = sa;
          return 0;
        case 12:
          el.focus();
          return 0;
        case 13: {
          const tag = sa.toLowerCase();
          if (!/^[a-z][a-z0-9-]*$/.test(tag) || badTags.includes(tag)) return fail(`dom create: the element "${sa}" is not allowed`);
          const e = (root.ownerDocument ?? document).createElement(tag);
          this._made.add(e);
          return handle(e);
        }
        case 14: {
          // append: `b` is the handle of the child as text.
          const kid = this._handles.get(Number(sb));
          if (!kid || !inScope(kid)) return fail(`invalid DOM handle "dom${sb}"`);
          if (kid === root || kid.contains(el)) return fail("dom append: an element cannot go below itself");
          el.appendChild(kid);
          return 0;
        }
        case 15:
          if (el === root) return fail("dom remove: the root stays");
          // The tree of the element leaves the scope with it.
          el.remove();
          this._made.delete(el);
          this._handles.delete(h);
          this._ids.delete(el);
          return 0;
        case 16:
          reply(el.innerHTML);
          return 0;
        case 17:
          if (!this._domHtml) return fail('dom html: setting HTML needs the grant "dom-html"');
          el.innerHTML = sa;
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

  /// Loads a C package that `zig cc -target wasm32-wasi` built with
  /// libztclstubs.a (docs/dev/cext-tasks/04w-wasm-bridge.md), and runs
  /// its init function, for example "Sqlite3_Init". The module needs a
  /// ztcl library built with `-Dcext-wasm`. `wasi` is the import object of
  /// `wasi_snapshot_preview1`, for example the wasiImport of a WASI of
  /// Node.js. With no `wasi`, the package gets no files: each call of
  /// WASI gives ENOSYS, except the clock and random bytes.
  async loadPackage(source, { init, wasi = null } = {}) {
    const mod = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    this._loadModule(mod, init, wasi);
  }

  // Makes an instance of the package module `mod` and runs `init`. The
  // instance is made at once, so the `load` command can call it.
  _loadModule(mod, init, wasi) {
    if (!this.x.ztcl_cext_command) throw new Error("loadPackage: this module has no C packages (build with -Dcext-wasm)");
    if (!init) throw new Error("loadPackage: no init function");
    const index = (this._pkgs ??= []).length;
    const pkg = { x: null, index };
    const imports = { ztcl: this._cextImports(pkg), wasi_snapshot_preview1: wasi ?? noWasi(pkg) };
    const instance = new WebAssembly.Instance(mod, imports);
    pkg.x = instance.exports;
    if (typeof pkg.x[init] !== "function") throw new Error(`loadPackage: the module has no export ${init}`);
    pkg.side = this._side(pkg.x);
    if (wasi?.initialize) wasi.initialize(instance);
    else pkg.x._initialize?.();
    this._pkgs.push(pkg);
    const ip = pkg.x.ztcl_cext_interp(this.h);
    pkg.ip = ip;
    const rc = pkg.x[init](ip);
    if (rc !== 0) {
      const r = new Uint32Array(pkg.x.memory.buffer, pkg.x.ztcl_cext_result(ip), 4);
      throw new Error(`${init}: ${decoder.decode(new Uint8Array(pkg.x.memory.buffer, r[2], r[1]))}`);
    }
  }

  /// Makes command `name` that runs `fn(args)` in JavaScript. The module
  /// needs a ztcl library built with `-Dcext-wasm`. `args` has the words
  /// after the name, as strings. `fn` gives the result, or throws an
  /// Error for a Tcl error with its message. In `fn`, eval() runs the
  /// script in the frame of the caller of the command.
  defineCommand(name, fn) {
    if (!this.x.ztcl_cext_command) throw new Error("defineCommand: this module has no C packages (build with -Dcext-wasm)");
    this._zside ??= this._side(this.x);
    const index = (this._pkgs ??= []).length;
    this._pkgs.push({ js: fn, index });
    const bytes = encoder.encode(name);
    const p = this._zside.xbuf(bytes.length);
    this._zside.view().u8.set(bytes, p);
    if (this.x.ztcl_cext_command(this.h, index, 0, p, bytes.length) !== 0) throw new Error("defineCommand: out of memory");
  }

  // Adds the command `load FILE ?PREFIX?` for the C packages of the
  // option `packages`. packages(file) gives a WebAssembly.Module, bytes,
  // or { module, wasi }, or null for no package.
  _addLoad(packages) {
    this.defineCommand("load", (args) => {
      if (args.length < 1 || args.length > 3) throw new Error('wrong # args: should be "load fileName ?prefix? ?interp?"');
      const file = args[0];
      let got = packages(file);
      if (!got) throw new Error(`couldn't load file "${file}": no such package`);
      if (got instanceof WebAssembly.Module || ArrayBuffer.isView(got) || got instanceof ArrayBuffer) got = { module: got };
      const mod = got.module instanceof WebAssembly.Module ? got.module : new WebAssembly.Module(got.module);
      this._loadModule(mod, initName(file, args[1]), got.wasi ?? null);
      return "";
    });
  }

  // The text of argument `i` of an `Arg` array at word `w0` of `side`.
  _argText(side, w0, i) {
    const v = side.view(), w = w0 + i * 4;
    const kind = v.u32[w], len = v.u32[w + 1];
    if (kind === 0) return decoder.decode(v.u8.subarray(v.u32[w + 2], v.u32[w + 2] + len));
    const dv = new DataView(side.buf, (w + 2) << 2, 8);
    if (kind === 1) return String(dv.getBigInt64(0, true));
    return doubleText(dv.getFloat64(0, true));
  }

  // Runs JavaScript command `fn` with the arguments at `argv` in ztcl.
  _jsCall(fn, argc, argv) {
    const zs = this._zside, w0 = argv >>> 2;
    const args = [];
    for (let i = 1; i < argc; i++) args.push(this._argText(zs, w0, i));
    let rc = 0, out;
    this._depth = (this._depth ?? 0) + 1;
    try {
      out = String(fn(args) ?? "");
    } catch (e) {
      rc = 1;
      out = String(e?.message ?? e);
    } finally {
      this._depth--;
    }
    const bytes = encoder.encode(out);
    const p = zs.xbuf(bytes.length);
    const v = zs.view();
    v.u8.set(bytes, p);
    v.u32[zs.reply] = 0; v.u32[zs.reply + 1] = bytes.length; v.u32[zs.reply + 2] = p; v.u32[zs.reply + 3] = 0;
    return rc;
  }

  // eval() inside a command of defineCommand: the script runs in the
  // frame of the caller, and the codes of Tcl stay.
  _evalIn(script) {
    const zs = this._zside;
    const bytes = encoder.encode(script);
    const p = zs.xbuf(bytes.length);
    zs.view().u8.set(bytes, p);
    const code = this.x.ztcl_cext_eval(this.h, p, bytes.length, 0);
    const result = this._argText(zs, zs.reply, 0);
    return { ok: code === 0, code, result, output: "" };
  }

  /// Frees the interpreter. Drop the Interp after this call.
  close() {
    if (this._timer !== null) clearTimeout(this._timer);
    this._timer = null;
    // The interp of each package goes first, so the delete procs of its
    // assoc data run.
    for (const pkg of this._pkgs ?? []) if (pkg.ip) pkg.x.ztcl_cext_interp_free(pkg.ip);
    this._pkgs = [];
    if (this.h) this.x.ztcl_delete(this.h);
    this.h = 0;
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
  _cextCall(pkgIndex, id, argc, argv, prec) {
    const pkg = this._pkgs[pkgIndex];
    if (pkg.js) return this._jsCall(pkg.js, argc, argv);
    const ps = pkg.side;
    // The package keeps its own copy of `tcl_precision`.
    if (ps.prec !== prec) {
      ps.x.ztcl_cext_precision?.(prec);
      ps.prec = prec;
    }
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
// The init function of `load FILE ?PREFIX?`, by the rule of Tcl: with
// no prefix, the letters and underscores at the start of the file name,
// after "lib". The first letter is upper case and the rest lower case.
function initName(file, prefix) {
  let p = prefix;
  if (!p) {
    let tail = file.slice(file.lastIndexOf("/") + 1);
    if (tail.startsWith("lib")) tail = tail.slice(3);
    p = /^[A-Za-z_]*/.exec(tail)[0];
  }
  return p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() + "_Init";
}

// The text of a double for a JavaScript command. A whole number keeps
// its ".0", as in Tcl.
function doubleText(d) {
  if (Number.isNaN(d)) return "NaN";
  if (!Number.isFinite(d)) return d > 0 ? "Inf" : "-Inf";
  const s = String(d);
  return /^-?\d+$/.test(s) ? s + ".0" : s;
}

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
