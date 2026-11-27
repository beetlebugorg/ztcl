// The host side of the commands `web::` of ztcl-host.wasm
// (src/wasmweb.zig, #251). web/ztcl.mjs loads this module only for an
// `allow` of a group `web:...`, so a page without the grant loads no
// bridge and no table.
//
// An object of the page is a handle `webN` in the table of a Bridge.
// The bridge calls only a member of the table of the Web IDL
// (web/webidl-table.mjs), and it converts each value by its type.
//
// SPDX-License-Identifier: BSD-2-Clause
import * as defaultTable from "./webidl-table.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const INTEGERS = {
  byte: [-128, 127],
  octet: [0, 255],
  short: [-32768, 32767],
  "unsigned short": [0, 65535],
  long: [-2147483648, 2147483647],
  "unsigned long": [0, 4294967295],
  "long long": [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER],
  "unsigned long long": [0, Number.MAX_SAFE_INTEGER],
};
const FLOATS = ["float", "double", "unrestricted float", "unrestricted double"];
const STRINGS = ["DOMString", "USVString", "ByteString", "any", "object"];
const BYTES = ["BufferSource", "AllowSharedBufferSource", "ArrayBuffer", "ArrayBufferView", "Uint8Array", "DataView"];

class WebError extends Error {}
const fail = (msg) => {
  throw new WebError(msg);
};

// Splits the outer layer of a type: "Promise<T>", "sequence<T>",
// "(A or B)", and "T?".
function parseType(t) {
  t = t.trim();
  if (t.endsWith("?")) return { kind: "nullable", of: t.slice(0, -1) };
  const m = /^(Promise|sequence|FrozenArray|ObservableArray)<(.*)>$/.exec(t);
  if (m) return { kind: m[1] === "Promise" ? "promise" : "sequence", of: m[2] };
  if (t.startsWith("(") && t.endsWith(")")) {
    const parts = [];
    let depth = 0;
    let start = 1;
    for (let i = 1; i < t.length - 1; i++) {
      const c = t[i];
      if (c === "<" || c === "(") depth++;
      else if (c === ">" || c === ")") depth--;
      else if (depth === 0 && t.startsWith(" or ", i)) {
        parts.push(t.slice(start, i));
        start = i + 4;
      }
    }
    parts.push(t.slice(start, t.length - 1));
    return { kind: "union", of: parts };
  }
  return { kind: "name", name: t.replace(/^\[[^\]]*\]\s*/, "") };
}

// The value of a Tcl boolean.
function tclBool(s) {
  const w = s.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(w)) return true;
  if (["0", "false", "no", "off"].includes(w)) return false;
  if (/^-?\d+$/.test(w)) return Number(w) !== 0;
  return fail(`web: expected boolean but got "${s}"`);
}

// Puts a reply of words and lists (see src/wasmweb.zig) into bytes.
export function encodeReply(node) {
  const parts = [];
  let size = 0;
  const put = (n) => {
    if (Array.isArray(n)) {
      const h = new Uint8Array(5);
      h[0] = 0x6c;
      new DataView(h.buffer).setUint32(1, n.length, true);
      parts.push(h);
      size += 5;
      for (const k of n) put(k);
      return;
    }
    const b = encoder.encode(String(n));
    const h = new Uint8Array(5);
    h[0] = 0x73;
    new DataView(h.buffer).setUint32(1, b.length, true);
    parts.push(h, b);
    size += 5 + b.length;
  };
  put(node);
  const out = new Uint8Array(size);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

// Reads the words of `bytes` (each one `s`, a length, and the bytes).
function decodeWords(bytes) {
  const out = [];
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 0;
  while (at + 5 <= bytes.length) {
    const n = dv.getUint32(at + 1, true);
    out.push(decoder.decode(bytes.subarray(at + 5, at + 5 + n)));
    at += 5 + n;
  }
  return out;
}

export class Bridge {
  /// `interp` is the Interp of web/ztcl.mjs, `groups` the granted
  /// groups ("serial" for "web:serial"), `root` the global object of the
  /// paths of `web::root` (globalThis by default), and `table` the table
  /// of the Web IDL.
  constructor(interp, { groups, root = globalThis, table = defaultTable }) {
    this.interp = interp;
    this.groups = new Set(groups);
    this.root = root;
    this.table = table;
    this.objs = new Map(); // id -> { obj, type }
    this.ids = new Map(); // obj -> id
    this.next = 1;
    // The results of the promises of `-command`, for runEvents.
    this.queue = [];
    // The listeners of `web::on` by "handle:event".
    this.listeners = new Map();
  }

  // The interface of an object of an event: the name of its class when
  // the table has it.
  typeOf(obj, fallback) {
    const n = obj?.constructor?.name;
    return n && this.table.interfaces[n] ? n : fallback;
  }

  // Puts the script of a result into the queue and asks the Interp for
  // a run of the events.
  push(script, vals, subst = false) {
    this.queue.push({ script, vals, subst });
    this.interp._kick();
  }

  // Gives the queue and empties it.
  take() {
    const q = this.queue;
    this.queue = [];
    return q;
  }

  get x() {
    return this.interp.x;
  }

  // The handle of `obj` as an object of the interface `type`.
  wrap(obj, type) {
    if (obj == null) return "";
    let id = this.ids.get(obj);
    if (id === undefined) {
      id = this.next++;
      this.ids.set(obj, id);
      this.objs.set(id, { obj, type });
    }
    return `web${id}`;
  }

  // The interface and the group of a member of `type`, after the check
  // of the grant.
  member(type, kind, name) {
    for (let t = type; t; t = this.table.interfaces[t]?.inherits) {
      const i = this.table.interfaces[t];
      if (!i) break;
      const m = i[kind]?.[name];
      if (!m) continue;
      // A member of a partial interface has the group of its own spec.
      const g = m.group ?? i.group;
      if (g != null && !this.groups.has(g)) fail(`web: the group "${g}" is not allowed`);
      return m;
    }
    const what = kind === "attributes" ? "attribute" : "method";
    return fail(`web: the interface "${type}" has no ${what} "${name}"`);
  }

  // Splits a Tcl list with the parser of the module.
  split(text) {
    const x = this.x;
    const b = encoder.encode(text);
    const p = x.ztcl_alloc(b.length || 1);
    if (!p) fail("web: out of memory");
    new Uint8Array(x.memory.buffer, p, b.length).set(b);
    const n = x.ztcl_web_split(p, b.length);
    x.ztcl_free(p, b.length || 1);
    if (n === -1) fail(`web: expected a list but got "${text}"`);
    if (n < 0) fail("web: out of memory");
    const slot = new Uint32Array(x.memory.buffer, x.ztcl_web_reply.value, 2);
    const [rp, rlen] = [slot[0], slot[1]];
    slot[0] = slot[1] = 0;
    const words = decodeWords(new Uint8Array(x.memory.buffer, rp + 5, rlen - 5).slice());
    x.ztcl_free(rp, rlen);
    return words;
  }

  // Converts the Tcl text `s` to a JavaScript value of the type `t`.
  toJS(t, s) {
    const p = parseType(t);
    if (p.kind === "nullable") return s === "" ? null : this.toJS(p.of, s);
    if (p.kind === "sequence") return this.split(s).map((w) => this.toJS(p.of, w));
    if (p.kind === "union") {
      let last;
      for (const k of p.of) {
        try {
          return this.toJS(k, s);
        } catch (e) {
          last = e;
        }
      }
      throw last;
    }
    if (p.kind === "promise") return fail(`web: a promise cannot be an argument`);
    const n = p.name;
    if (n === "boolean") return tclBool(s);
    if (n in INTEGERS) {
      const v = Number(s.trim());
      const [lo, hi] = INTEGERS[n];
      if (s.trim() === "" || !Number.isInteger(v)) fail(`web: expected integer but got "${s}"`);
      if (v < lo || v > hi) fail(`web: the integer ${s} is out of the range of ${n}`);
      return v;
    }
    if (FLOATS.includes(n)) {
      const v = Number(s.trim());
      if (s.trim() === "" || Number.isNaN(v)) fail(`web: expected number but got "${s}"`);
      return v;
    }
    if (STRINGS.includes(n)) return s;
    if (BYTES.includes(n)) {
      const out = new Uint8Array(s.length);
      for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c > 255) fail(`web: the character U+${c.toString(16).toUpperCase().padStart(4, "0")} is not a byte`);
        out[i] = c;
      }
      return out;
    }
    const tb = this.table;
    if (tb.typedefs?.[n]) return this.toJS(tb.typedefs[n], s);
    if (tb.enums?.[n]) {
      if (!tb.enums[n].includes(s)) fail(`web: bad value "${s}" of ${n}: must be ${tb.enums[n].join(", ")}`);
      return s;
    }
    if (tb.dictionaries?.[n]) return this.dictToJS(n, s);
    if (n === "EventHandler") fail("web: an event handler cannot be set");
    // An interface type: a handle.
    const m = /^web(\d+)$/.exec(s);
    const o = m && this.objs.get(Number(m[1]));
    if (!o) fail(`invalid web handle "${s}"`);
    if (!this.isA(o.type, n)) fail(`web: the handle "${s}" is a ${o.type || "object"}, not a ${n}`);
    return o.obj;
  }

  isA(type, want) {
    for (let t = type; t; t = this.table.interfaces[t]?.inherits) if (t === want) return true;
    return false;
  }

  // The members of the dictionary `n` and of the dictionaries that it
  // inherits.
  dictMembers(n) {
    const out = {};
    for (let d = n; d; d = this.table.dictionaries[d]?.inherits) Object.assign(out, this.table.dictionaries[d]?.members);
    return out;
  }

  dictToJS(n, s) {
    const members = this.dictMembers(n);
    const words = this.split(s);
    if (words.length % 2) fail(`web: missing value to go with key "${words[words.length - 1]}" of ${n}`);
    const out = {};
    for (let i = 0; i < words.length; i += 2) {
      const m = members[words[i]];
      if (!m) fail(`web: the dictionary ${n} has no member "${words[i]}"`);
      out[words[i]] = this.toJS(m.type, words[i + 1]);
    }
    for (const [k, m] of Object.entries(members)) if (m.required && !(k in out)) fail(`web: the member "${k}" of ${n} is required`);
    return out;
  }

  // Converts a JavaScript value of the type `t` to a word or a list.
  fromJS(t, v) {
    const p = parseType(t);
    if (v === undefined || v === null) return "";
    if (p.kind === "nullable") return this.fromJS(p.of, v);
    if (p.kind === "sequence") return Array.from(v, (e) => this.fromJS(p.of, e));
    if (p.kind === "union") {
      for (const k of p.of) {
        const kp = parseType(k);
        if (kp.kind === "name" && (kp.name in INTEGERS || FLOATS.includes(kp.name)) && typeof v === "number") return String(v);
        if (kp.kind === "name" && STRINGS.includes(kp.name) && typeof v === "string") return v;
      }
      return this.fromJS(p.of[0], v);
    }
    const n = p.name;
    if (n === "undefined") return "";
    if (n === "boolean") return v ? "1" : "0";
    if (n in INTEGERS || FLOATS.includes(n)) return String(v);
    if (STRINGS.includes(n) || this.table.enums?.[n]) return String(v);
    if (BYTES.includes(n)) {
      const b = v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
      let s = "";
      for (let i = 0; i < b.length; i += 8192) s += String.fromCharCode(...b.subarray(i, i + 8192));
      return s;
    }
    if (this.table.typedefs?.[n]) return this.fromJS(this.table.typedefs[n], v);
    if (this.table.dictionaries?.[n]) {
      const out = [];
      for (const [k, m] of Object.entries(this.dictMembers(n))) if (v[k] !== undefined) out.push(k, this.fromJS(m.type, v[k]));
      return out;
    }
    if (n === "EventHandler") return "";
    return this.wrap(v, n);
  }

  obj(h) {
    const o = this.objs.get(h);
    if (!o) fail(`invalid web handle "web${h}"`);
    return o;
  }

  // The import `ztcl_host.web` (src/wasmweb.zig).
  call(op, h, a, aLen, b, bLen) {
    const x = this.x;
    const reply = (node) => {
      const bytes = encodeReply(node);
      const p = x.ztcl_alloc(bytes.length);
      new Uint8Array(x.memory.buffer, p, bytes.length).set(bytes);
      const slot = new Uint32Array(x.memory.buffer, x.ztcl_web_reply.value, 2);
      slot[0] = p;
      slot[1] = bytes.length;
    };
    try {
      const sa = decoder.decode(new Uint8Array(x.memory.buffer, a, aLen));
      const args = decodeWords(new Uint8Array(x.memory.buffer, b, bLen).slice());
      switch (op) {
        case 1: {
          const type = this.table.roots[sa];
          if (!type) fail(`web: no root "${sa}": must be ${Object.keys(this.table.roots).sort().join(", ")}`);
          // `navigator` and `window` have no group: each member has one.
          const group = this.table.interfaces[type]?.group;
          if (group != null && !this.groups.has(group)) fail(`web: the group "${group}" is not allowed`);
          let obj = this.root;
          for (const k of sa.split(".")) if (k !== "window") obj = obj?.[k];
          if (obj == null) fail(`web: this browser has no ${sa}`);
          this.wrap(obj, type);
          return this.ids.get(obj);
        }
        case 2: {
          const o = this.obj(h);
          const m = this.member(o.type, "attributes", sa);
          if (m.type === "EventHandler") fail(`web: the attribute "${sa}" is an event handler: use web::on`);
          reply(this.fromJS(m.type, o.obj[sa]));
          return 0;
        }
        case 3: {
          const o = this.obj(h);
          const m = this.member(o.type, "attributes", sa);
          if (m.readonly) fail(`web: the attribute "${sa}" of ${o.type} is read-only`);
          if (m.type === "EventHandler") fail(`web: the attribute "${sa}" is an event handler: use web::on`);
          o.obj[sa] = this.toJS(m.type, args[0]);
          return 0;
        }
        case 4: {
          const o = this.obj(h);
          const m = this.member(o.type, "operations", sa);
          const ret = parseType(m.returns);
          if (ret.kind === "promise") fail(`web: the method "${sa}" gives a promise: use -command`);
          reply(this.fromJS(m.returns, o.obj[sa](...this.args(o.type, sa, m, args))));
          return 0;
        }
        case 5:
          this.release(h);
          return 0;
        case 6: {
          // A call with -command: the first word is the script.
          const o = this.obj(h);
          const m = this.member(o.type, "operations", sa);
          const ret = parseType(m.returns);
          if (ret.kind !== "promise") fail(`web: the method "${sa}" gives no promise: leave out -command`);
          const script = args[0];
          const p = o.obj[sa](...this.args(o.type, sa, m, args.slice(1)));
          Promise.resolve(p).then(
            (v) => {
              let word;
              try {
                word = this.fromJS(ret.of, v);
              } catch (e) {
                return this.push(script, ["error", e instanceof WebError ? e.message : errorText(e)]);
              }
              this.push(script, ["ok", word]);
            },
            (e) => this.push(script, ["error", errorText(e)]),
          );
          return 0;
        }
        case 7: {
          // on: `sa` is the event type and the first word the script.
          const o = this.obj(h);
          if (!/^[a-z][a-z0-9_-]*$/.test(sa)) fail(`web::on: bad event "${sa}"`);
          const m = this.member(o.type, "attributes", `on${sa}`);
          if (m.type !== "EventHandler") fail(`web: the interface "${o.type}" has no event "${sa}"`);
          const key = `${h}:${sa}`;
          this.off(key);
          const script = args[0];
          const fn = (ev) => {
            if (!this.objs.has(h)) return;
            const t = ev.target;
            const target = t && t !== o.obj ? this.wrap(t, this.typeOf(t, "EventTarget")) : t ? `web${h}` : "";
            let detail = "";
            if (ev.detail !== undefined && ev.detail !== null) detail = typeof ev.detail === "object" ? "" : String(ev.detail);
            this.push(script, [String(ev.type), target, detail], true);
          };
          o.obj.addEventListener(sa, fn);
          this.listeners.set(key, { obj: o.obj, type: sa, fn });
          return 0;
        }
        case 8:
          this.obj(h);
          this.off(`${h}:${sa}`);
          return 0;
      }
      return fail(`web: unknown operation ${op}`);
    } catch (e) {
      reply(e instanceof WebError ? e.message : errorText(e));
      return -1;
    }
  }

  // The JavaScript arguments of the method `name` from the words of Tcl.
  args(type, name, m, words) {
    const need = m.args.filter((p) => !p.optional && !p.variadic).length;
    const variadic = m.args.length && m.args[m.args.length - 1].variadic;
    if (words.length < need || (!variadic && words.length > m.args.length)) {
      const usage = m.args.map((p) => (p.optional ? `?${p.name}?` : p.variadic ? `?${p.name} ...?` : p.name)).join(" ");
      fail(`web: wrong # args: should be "web::call obj ${name}${usage ? " " + usage : ""}"`);
    }
    return words.map((w, i) => this.toJS(m.args[Math.min(i, m.args.length - 1)].type, w));
  }

  off(key) {
    const old = this.listeners.get(key);
    if (old) old.obj.removeEventListener(old.type, old.fn);
    this.listeners.delete(key);
  }

  release(h) {
    const o = this.obj(h);
    for (const key of [...this.listeners.keys()]) if (key.startsWith(`${h}:`)) this.off(key);
    this.objs.delete(h);
    this.ids.delete(o.obj);
  }
}

/// The text of an error of the page: the name and the message of a
/// DOMException or an Error, after "web: ".
export function errorText(e) {
  if (e && typeof e === "object" && e.name && e.message !== undefined) return `web: ${e.name}: ${e.message}`;
  return `web: ${String(e)}`;
}
