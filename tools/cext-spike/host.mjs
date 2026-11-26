// Spike (cext task 02): runs a SQLite test file in ztcl-host.wasm under
// Node.js. sqlite.wasm (the Tcl binding of SQLite and wshim.c) calls
// each Tcl_* slot as an import. The imports below implement the slots
// with shadow Tcl_Obj records in the memory of sqlite.wasm, and forward
// commands, scripts, and variables to ztcl as text with the kind of
// each value.
// Usage: node host.mjs ZTCL_WASM SQLITE_WASM WORKDIR SLOTS_OUT script.tcl [args]
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import path from "node:path";
import { WASI } from "node:wasi";

const [ztclPath, sqlPath, work, slotsOut, script, ...scriptArgs] = process.argv.slice(2);
const enc = new TextEncoder(), dec = new TextDecoder();

// ---- ztcl ----
let Z, h, depth = 0;
const zmem = () => new Uint8Array(Z.memory.buffer);
const zstr = (p, n) => dec.decode(zmem().subarray(p >>> 0, (p >>> 0) + (n >>> 0)));
function zput(s) {
  const b = enc.encode(s), p = Z.ztcl_alloc(Math.max(b.length, 1)) >>> 0;
  zmem().set(b, p);
  return [p, b.length];
}
function zeval(s) {
  const [p, n] = zput(s);
  // At the top, ztcl_eval sets up the scan range of the collector.
  // Inside a command of the module, ztcl_cext_eval keeps the codes.
  const code = depth ? Z.ztcl_cext_eval(h, p, n) : Z.ztcl_eval(h, p, n);
  Z.ztcl_free(p, Math.max(n, 1));
  const tag = new DataView(Z.memory.buffer).getUint32(Z.ztcl_cext_tag.value, true);
  return { code, result: zstr(Z.ztcl_result_ptr(h), Z.ztcl_result_len(h)), tag };
}
function zreply(s) {
  if (s.length === 0) return;
  const [p, n] = zput(s);
  const dv = new DataView(Z.memory.buffer);
  const at = Z.ztcl_cext_reply.value;
  dv.setUint32(at, p, true);
  dv.setUint32(at + 4, n, true);
}

// ---- Tcl lists, in text ----
function quote(s) {
  if (s === "") return "{}";
  if (!/[\s{}\[\]$"\\;]/.test(s) && s[0] !== "#") return s;
  let depth = 0, ok = !s.endsWith("\\");
  for (const c of s) {
    if (c === "{") depth++;
    else if (c === "}" && --depth < 0) ok = false;
  }
  if (ok && depth === 0 && !/\\/.test(s)) return "{" + s + "}";
  return s.replace(/([\s{}\[\]$"\\;])/g, (m) => (m === "\n" ? "\\n" : m === "\t" ? "\\t" : "\\" + m)).replace(/^#/, "\\#");
}
// The text of a list comes from the `list` command of ztcl, so that the
// quoting of each element is the quoting of Tcl. quote() gives a form
// that parses back to the same element.
function zlist(items) {
  if (items.length === 0) return "";
  const r = zeval("list " + items.map(quote).join(" "));
  if (r.code !== 0) throw new Error("list: " + r.result);
  return r.result;
}
function splitList(s) {
  const out = [];
  let i = 0;
  const ws = (c) => c === " " || c === "\t" || c === "\n" || c === "\r" || c === "\v" || c === "\f";
  for (;;) {
    while (i < s.length && ws(s[i])) i++;
    if (i >= s.length) return out;
    if (s[i] === "{") {
      let d = 1, j = i + 1;
      while (j < s.length && d > 0) {
        if (s[j] === "\\") j++;
        else if (s[j] === "{") d++;
        else if (s[j] === "}") d--;
        j++;
      }
      if (d) throw new Error("unmatched open brace in list");
      out.push(s.slice(i + 1, j - 1));
      i = j;
    } else {
      const q = s[i] === '"';
      let j = q ? i + 1 : i, t = "";
      while (j < s.length && (q ? s[j] !== '"' : !ws(s[j]))) {
        if (s[j] === "\\") {
          const c = s[++j];
          t += c === "n" ? "\n" : c === "t" ? "\t" : c === "r" ? "\r" : c === undefined ? "\\" : c;
        } else t += s[j];
        j++;
      }
      out.push(t);
      i = q ? j + 1 : j;
    }
  }
}

// ---- sqlite.wasm memory and shadow objects ----
let M, table;
// The views of the memory of the module, made again after it grows.
let vBuf = null, vU8 = null, vDv = null;
function views() { if (M.memory.buffer !== vBuf) { vBuf = M.memory.buffer; vU8 = new Uint8Array(vBuf); vDv = new DataView(vBuf); } }
const u8 = () => (views(), vU8);
const dv = () => (views(), vDv);
const rd = (p) => dv().getUint32(p, true), wr = (p, v) => dv().setUint32(p, v, true);
function cstr(p, n = -1) {
  if (!p) return "";
  const m = u8();
  if (n < 0) { n = 0; while (m[p + n]) n++; }
  return dec.decode(m.subarray(p, p + n)).replace(/\uFFFD\uFFFD/g, "\0");
}
function modUtf(s) {
  // Tcl keeps U+0000 as the two bytes C0 80.
  const parts = s.split("\0").map((x) => enc.encode(x));
  let n = parts.reduce((a, b) => a + b.length, 0) + 2 * (parts.length - 1);
  const out = new Uint8Array(n);
  let o = 0;
  parts.forEach((b, i) => { if (i) { out[o++] = 0xc0; out[o++] = 0x80; } out.set(b, o); o += b.length; });
  return out;
}
function cput(s) {
  const b = modUtf(s), p = M.malloc(b.length + 1);
  u8().set(b, p); u8()[p + b.length] = 0;
  return p;
}

const objs = new Map();
const types = {};
function newObj(rec) {
  const p = M.malloc(24);
  u8().fill(0, p, p + 24);
  objs.set(p, rec);
  setType(p, rec);
  return p;
}
function setType(p, rec) {
  wr(p + 12, rec.b ? types.bytearray : rec.w !== undefined ? types.wideInt : rec.d !== undefined ? types.double : rec.l ? types.list : 0);
  if (rec.s === undefined) { dropBytes(p, rec); wr(p + 4, 0); wr(p + 8, 0); }
}
function dropBytes(p, rec) { if (rec.bp) { M.free(rec.bp); rec.bp = 0; } if (rec.bb) { M.free(rec.bb); rec.bb = 0; } if (rec.av) { M.free(rec.av); rec.av = 0; } }
function str(p) {
  const r = objs.get(p);
  if (!r) throw new Error("not a Tcl_Obj: " + p);
  if (r.s !== undefined) return r.s;
  if (r.b) r.s = String.fromCharCode(...r.b);
  else if (r.w !== undefined) r.s = r.w.toString();
  else if (r.d !== undefined) r.s = fmtDouble(r.d);
  else if (r.l) r.s = zlist(r.l.map(str));
  else r.s = "";
  return r.s;
}
// The form of a double in Tcl 8.6: the shortest digits that give the
// same double, as %g with an exponent below -4 or from 17 on, and ".0"
// after an integer.
// With tcl_precision above 0, the form is %.<precision>g, as in Tcl.
let precision = 0;
function fmtDouble(d) {
  if (precision > 0 && isFinite(d) && d !== 0) {
    const [m, ex] = d.toExponential(precision - 1).split("e");
    const e = Number(ex);
    if (e < -4 || e >= precision) return m.replace(/\.?0+$/, "") + "e" + (e < 0 ? "-" : "+") + String(Math.abs(e)).padStart(2, "0");
    let f = d.toFixed(Math.max(0, precision - 1 - e));
    if (f.includes(".")) f = f.replace(/\.?0+$/, "");
    return f.includes(".") || f.includes("e") ? f : f + ".0";
  }
  if (!isFinite(d)) return isNaN(d) ? "NaN" : d > 0 ? "Inf" : "-Inf";
  if (d === 0) return Object.is(d, -0) ? "-0.0" : "0.0";
  const [m, ex] = d.toExponential().split("e");
  const e = Number(ex), neg = m[0] === "-";
  const digits = m.replace("-", "").replace(".", "");
  let out;
  if (e < -4 || e >= 17) {
    out = digits[0] + (digits.length > 1 ? "." + digits.slice(1) : "") + "e" + (e < 0 ? "-" : "+") + String(Math.abs(e)).padStart(2, "0");
  } else if (e < 0) {
    out = "0." + "0".repeat(-e - 1) + digits;
  } else if (digits.length <= e + 1) {
    out = digits + "0".repeat(e + 1 - digits.length) + ".0";
  } else {
    out = digits.slice(0, e + 1) + "." + digits.slice(e + 1);
  }
  return (neg ? "-" : "") + out;
}
function strBytes(p) {
  const r = objs.get(p), s = str(p);
  if (!r.bp) {
    const b = modUtf(s);
    r.bp = M.malloc(b.length + 1);
    u8().set(b, r.bp); u8()[r.bp + b.length] = 0;
    r.blen = b.length;
  }
  wr(p + 4, r.bp); wr(p + 8, r.blen);
  return r.bp;
}
function changed(p, rec) {
  const r = objs.get(p);
  if (r.l && r.l !== rec.l) for (const e of r.l) decr(e);
  dropBytes(p, r);
  for (const k of ["s", "b", "w", "d", "l"]) delete r[k];
  Object.assign(r, rec);
  setType(p, r);
}
function incr(p) { wr(p, rd(p) + 1); }
function decr(p) { const n = rd(p) - 1; wr(p, n); if (n <= 0) freeObj(p); }
function freeObj(p) {
  const r = objs.get(p);
  if (!r) return;
  objs.delete(p);
  dropBytes(p, r);
  if (r.l) for (const e of r.l) decr(e);
  M.free(p);
}
function listOf(p) {
  const r = objs.get(p);
  if (!r.l) {
    const items = splitList(str(p)).map((s) => { const e = newObj({ s }); incr(e); return e; });
    r.l = items;
  }
  return r.l;
}
function intOf(p) {
  const r = objs.get(p);
  if (r.w !== undefined) return r.w;
  if (r.d !== undefined && Number.isInteger(r.d)) return null;
  const s = str(p).trim();
  if (/^[+-]?(0x[0-9a-f]+|0b[01]+|0o[0-7]+|[0-9]+)$/i.test(s)) {
    const neg = s[0] === "-";
    const t = s.replace(/^[+-]/, "").replace(/^0o/i, "0o");
    const v = BigInt(t);
    return neg ? -v : v;
  }
  return null;
}
function doubleOf(p) {
  const r = objs.get(p);
  if (r.d !== undefined) return r.d;
  if (r.w !== undefined) return Number(r.w);
  const s = str(p).trim();
  const i = intOf(p);
  if (i !== null) return Number(i);
  if (/^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(s) || /^[+-]?(inf|infinity|nan)$/i.test(s)) return Number(s.replace(/inf(inity)?/i, "Infinity"));
  return null;
}

// ---- The interp state of the module ----
let interpPtr = 0, result = 0; // result: a Tcl_Obj
function setResult(p) { if (p) incr(p); if (result) decr(result); result = p; }
function setResultStr(s) { setResult(newObj({ s })); }
function resultStr() { return result ? str(result) : ""; }
const cmds = new Map();
const slotCount = new Map(); // import name -> calls that the shim did not record
let nrFrames = [];

function callFn(fp, ...a) { return table.get(fp)(...a); }

// A value of ztcl keeps its kind: an int or a double gets the typePtr
// of Tcl, as the binding reads typePtr->name to bind a variable.
function typed(s, tag) {
  if (tag === 1) return { s, w: BigInt(s) };
  if (tag === 2) { const d = Number(s.replace(/Inf/, "Infinity")); return { s, d }; }
  return { s };
}
// In Tcl, the variable owns the object of Tcl_GetVar2Ex and of
// Tcl_ObjSetVar2. Here the variable is in ztcl, so the object with no
// reference is freed when the command that got it ends.
const pendingFree = [];
function later(p) { pendingFree.push(p); return p; }
function runCommand(c, argv, tags = []) {
  const mark = pendingFree.length;
  precision = readPrecision();
  setResult(0);
  const objv = M.malloc(4 * argv.length);
  const ps = argv.map((s, i) => { const o = newObj(typed(s, tags[i])); incr(o); return o; });
  ps.forEach((o, i) => wr(objv + 4 * i, o));
  let rc;
  if (c.nre) {
    nrFrames.push({ evals: null, cbs: [] });
    rc = callFn(c.nre, c.cd, interpPtr, argv.length, objv);
    rc = runNR(rc);
  } else rc = callFn(c.proc, c.cd, interpPtr, argv.length, objv);
  ps.forEach(decr);
  M.free(objv);
  for (const p of pendingFree.splice(mark)) if (objs.has(p) && rd(p) <= 0) freeObj(p);
  return rc;
}
// The non-recursive engine of Tcl 8.6: after a function returns, its
// eval of Tcl_NREvalObj runs, then its callbacks, last in first. A
// callback can add an eval and callbacks, and they run before the rest.
// One loop runs them, so a long `db eval` with a script uses no stack.
function runNR(rc) {
  const f = nrFrames.pop();
  let pend = f.evals;
  const stack = f.cbs;
  for (;;) {
    if (pend) {
      rc = evalObj(str(pend.obj), pend.flags);
      decr(pend.obj);
      pend = null;
    }
    if (!stack.length) return rc;
    const cb = stack.pop();
    const data = M.malloc(16);
    cb.d.forEach((v, i) => wr(data + 4 * i, v));
    nrFrames.push({ evals: null, cbs: [] });
    rc = callFn(cb.proc, data, interpPtr, rc);
    M.free(data);
    const g = nrFrames.pop();
    pend = g.evals;
    stack.push(...g.cbs);
  }
}
function evalObj(s, flags) {
  if (flags & 0x20000) s = "uplevel #0 " + quote(s);
  const r = zeval(s);
  setResult(newObj(typed(r.result, r.tag)));
  return r.code;
}
function varName(n1, n2, flags) {
  let n = n2 ? `${n1}(${n2})` : n1;
  if (flags & 1 && !n.startsWith("::")) n = "::" + n;
  return n;
}
const ztag = () => new DataView(Z.memory.buffer).getUint32(Z.ztcl_cext_tag.value, true);
const zres = () => zstr(Z.ztcl_result_ptr(h), Z.ztcl_result_len(h));
function getVar(n, flags) {
  const [p, k] = zput(n);
  const rc = Z.ztcl_cext_get(h, p, k);
  Z.ztcl_free(p, Math.max(k, 1));
  if (rc !== 0) { if (flags & 0x200) setResultStr(zres()); return 0; }
  return later(newObj(typed(zres(), ztag())));
}
function readPrecision() {
  const [p, k] = zput("::tcl_precision");
  const rc = Z.ztcl_cext_get(h, p, k);
  Z.ztcl_free(p, k);
  return rc === 0 ? Number(zres()) || 0 : 0;
}
function setVar(n, obj, flags) {
  const r = objs.get(obj), v = str(obj);
  const tag = r.w !== undefined ? 1 : r.d !== undefined ? 2 : 0;
  const [np, nk] = zput(n), [vp, vk] = zput(v);
  const rc = Z.ztcl_cext_set(h, np, nk, vp, vk, tag);
  Z.ztcl_free(np, Math.max(nk, 1)); Z.ztcl_free(vp, Math.max(vk, 1));
  if (rc !== 0) { if (flags & 0x200) setResultStr(zres()); return false; }
  return true;
}
function vaStrings(va) { const out = []; for (let p = va; ; p += 4) { const s = rd(p); if (!s) return out; out.push(cstr(s)); } }
function dsAppend(ds, bytes) {
  const len = rd(ds + 4), cap = rd(ds + 8), cur = rd(ds);
  if (len + bytes.length >= cap) {
    const ncap = 2 * (len + bytes.length) + 1, np = M.malloc(ncap);
    u8().copyWithin(np, cur, cur + len);
    if (cur !== ds + 12) M.free(cur);
    wr(ds, np); wr(ds + 8, ncap);
  }
  const p = rd(ds);
  u8().set(bytes, p + len);
  u8()[p + len + bytes.length] = 0;
  wr(ds + 4, len + bytes.length);
}
function dsInit(ds) { wr(ds, ds + 12); wr(ds + 4, 0); wr(ds + 8, 200); u8()[ds + 12] = 0; }

const T = {
  Tcl_PkgProvideEx: () => 0,
  Tcl_PkgRequireEx: () => cput("8.6.16"),
  Tcl_Alloc: (n) => M.malloc(n),
  Tcl_Free: (p) => M.free(p),
  Tcl_DuplicateObj: (p) => { const r = objs.get(p); const c = { ...r }; delete c.bp; delete c.bb; delete c.av; if (c.l) { c.l = [...c.l]; c.l.forEach(incr); } return newObj(c); },
  TclFreeObj: (p) => freeObj(p),
  Tcl_GetBooleanFromObj: (ip, p, out) => {
    const s = str(p).trim().toLowerCase();
    let v = null;
    if (["1", "true", "yes", "on", "tru", "tr", "t", "ye", "y"].includes(s)) v = 1;
    else if (["0", "false", "no", "off", "fals", "fal", "fa", "f", "n", "of"].includes(s)) v = 0;
    else { const d = doubleOf(p); if (d !== null) v = d ? 1 : 0; }
    if (v === null) { if (ip) setResultStr(`expected boolean value but got "${str(p)}"`); return 1; }
    wr(out, v); return 0;
  },
  Tcl_GetByteArrayFromObj: (p, lenp) => {
    const r = objs.get(p);
    const b = r.b || Uint8Array.from(str(p), (c) => c.charCodeAt(0) & 0xff);
    if (r.bb) M.free(r.bb);
    r.bb = M.malloc(b.length + 1);
    u8().set(b, r.bb);
    if (lenp) wr(lenp, b.length);
    return r.bb;
  },
  Tcl_GetDoubleFromObj: (ip, p, out) => {
    const d = doubleOf(p);
    if (d === null) { if (ip) setResultStr(`expected floating-point number but got "${str(p)}"`); return 1; }
    dv().setFloat64(out, d, true); return 0;
  },
  Tcl_GetIntFromObj: (ip, p, out) => {
    const v = intOf(p);
    if (v === null || v > 0xffffffffn || v < -0x80000000n) { if (ip) setResultStr(`expected integer but got "${str(p)}"`); return 1; }
    dv().setInt32(out, Number(BigInt.asIntN(32, v)), true); return 0;
  },
  Tcl_GetWideIntFromObj: (ip, p, out) => {
    const v = intOf(p);
    if (v === null) { if (ip) setResultStr(`expected integer but got "${str(p)}"`); return 1; }
    dv().setBigInt64(out, BigInt.asIntN(64, v), true); return 0;
  },
  Tcl_GetStringFromObj: (p, lenp) => { const b = strBytes(p); if (lenp) wr(lenp, objs.get(p).blen); return b; },
  Tcl_GetString: (p) => strBytes(p),
  Tcl_ListObjAppendElement: (ip, p, e) => {
    const l = listOf(p);
    incr(e);
    l.push(e);
    changed(p, { l });
    return 0;
  },
  Tcl_ListObjGetElements: (ip, p, nOut, vOut) => {
    let l;
    try { l = listOf(p); } catch (e) { if (ip) setResultStr(e.message); return 1; }
    const r = objs.get(p);
    if (r.av) M.free(r.av);
    r.av = M.malloc(4 * l.length + 4);
    l.forEach((e, i) => wr(r.av + 4 * i, e));
    wr(nOut, l.length); wr(vOut, r.av);
    return 0;
  },
  Tcl_NewByteArrayObj: (b, n) => newObj({ b: u8().slice(b, b + n) }),
  Tcl_NewDoubleObj: (d) => newObj({ d }),
  Tcl_NewIntObj: (i) => newObj({ w: BigInt(i) }),
  Tcl_NewWideIntObj: (w) => newObj({ w }),
  Tcl_NewListObj: (n, v) => { const l = []; for (let i = 0; i < n; i++) { const e = rd(v + 4 * i); incr(e); l.push(e); } return newObj({ l }); },
  Tcl_NewObj: () => newObj({ s: "" }),
  Tcl_NewStringObj: (b, n) => newObj({ s: cstr(b, n) }),
  Tcl_SetIntObj: (p, i) => changed(p, { w: BigInt(i) }),
  Tcl_SetWideIntObj: (p, w) => changed(p, { w }),
  Tcl_AppendResult: (ip, va) => setResultStr(resultStr() + vaStrings(va).join("")),
  Tcl_BackgroundError: () => { process.stderr.write("background error: " + resultStr() + "\n"); },
  Tcl_CreateChannel: () => 0,
  Tcl_GetChannelName: () => cput(""),
  Tcl_RegisterChannel: () => {},
  Tcl_UnregisterChannel: () => 0,
  Tcl_CreateObjCommand: (ip, name, proc, cd, del) => addCmd(cstr(name), { proc, cd, del }),
  Tcl_NRCreateCommand: (ip, name, proc, nre, cd, del) => addCmd(cstr(name), { proc, nre, cd, del }),
  Tcl_DeleteCommand: (ip, name) => {
    const n = cstr(name).replace(/^::/, "");
    const id = byName.get(n), c = cmds.get(id);
    if (!c) return -1;
    cmds.delete(id); byName.delete(n);
    zeval("rename " + quote(n) + " {}");
    if (c.del) callFn(c.del, c.cd);
    return 0;
  },
  Tcl_DStringInit: (ds) => dsInit(ds),
  Tcl_DStringAppend: (ds, b, n) => { const m = u8(); if (n < 0) { n = 0; while (m[b + n]) n++; } dsAppend(ds, m.slice(b, b + n)); return rd(ds); },
  Tcl_DStringAppendElement: (ds, b) => { const s = zlist([cstr(b)]); dsAppend(ds, modUtf((rd(ds + 4) ? " " : "") + s)); return rd(ds); },
  Tcl_DStringFree: (ds) => { if (rd(ds) !== ds + 12) M.free(rd(ds)); dsInit(ds); },
  Tcl_Eval: (ip, s) => evalObj(cstr(s), 0),
  Tcl_GlobalEval: (ip, s) => evalObj(cstr(s), 0x20000),
  Tcl_VarEval: (ip, va) => evalObj(vaStrings(va).join(""), 0),
  Tcl_EvalObjEx: (ip, p, flags) => { incr(p); const rc = evalObj(str(p), flags); decr(p); return rc; },
  Tcl_GetObjResult: () => { if (!result) setResultStr(""); return result; },
  Tcl_GetStringResult: () => { if (!result) setResultStr(""); return strBytes(result); },
  Tcl_ObjSetVar2: (ip, p1, p2, v, flags) => { incr(v); const ok = setVar(varName(str(p1), p2 ? str(p2) : null, flags), v, flags); if (!ok) { decr(v); return 0; } wr(v, rd(v) - 1); return later(v); },
  Tcl_GetVar2Ex: (ip, n1, n2, flags) => getVar(varName(cstr(n1), n2 ? cstr(n2) : null, flags), flags),
  Tcl_ResetResult: () => setResult(0),
  Tcl_SetResult: (ip, s, free) => { setResultStr(s ? cstr(s) : ""); if (free === 3) M.free(s); else if (free > 3) callFn(free, s); },
  Tcl_SetObjResult: (ip, p) => setResult(p),
  Tcl_TranslateFileName: (ip, name, ds) => { dsInit(ds); dsAppend(ds, modUtf(cstr(name))); return rd(ds); },
  Tcl_WrongNumArgs: (ip, n, v, msg) => {
    const w = []; for (let i = 0; i < n; i++) w.push(str(rd(v + 4 * i)));
    if (msg) w.push(cstr(msg));
    setResultStr(`wrong # args: should be "${w.join(" ")}"`);
  },
  Tcl_GetVersion: (a, b, c, d) => { if (a) wr(a, 8); if (b) wr(b, 6); if (c) wr(c, 16); if (d) wr(d, 2); },
  Tcl_GetIndexFromObjStruct: (ip, p, tab, off, msg, flags, out) => {
    const key = str(p), names = [];
    for (let e = tab; rd(e); e += off) names.push(cstr(rd(e)));
    let hit = names.indexOf(key);
    if (hit < 0 && !(flags & 1) && key) {
      const m = names.map((n, i) => [n, i]).filter(([n]) => n.startsWith(key));
      if (m.length === 1) hit = m[0][1];
    }
    if (hit < 0) {
      if (ip) {
        const l = names.filter((n) => n);
        const list = l.length === 1 ? l[0] : l.slice(0, -1).join(", ") + (l.length > 2 ? "," : "") + " or " + l[l.length - 1];
        setResultStr(`bad ${cstr(msg)} "${key}": must be ${list}`);
      }
      return 1;
    }
    wr(out, hit); return 0;
  },
  Tcl_NREvalObj: (ip, p, flags) => { incr(p); nrFrames[nrFrames.length - 1].evals = { obj: p, flags }; return 0; },
  Tcl_NRAddCallback: (ip, proc, a, b, c, d) => { nrFrames[nrFrames.length - 1].cbs.push({ proc, d: [a, b, c, d] }); },
};
// Each command of the module is a proc that calls __cext_call with its
// id and the name of the call, in the frame of the caller (tailcall).
const byName = new Map();
let nextId = 1;
function addCmd(name, c) {
  name = name.replace(/^::/, "");
  const id = nextId++;
  cmds.set(id, c);
  byName.set(name, id);
  zeval(`proc ${quote(name)} args { tailcall __cext_call ${id} [lindex [info level 0] 0] {*}$args }`);
  return id;
}

// Commands of the host for the test scripts, in place of the file and
// channel commands that ztcl-host.wasm does not have.
const W = (n) => path.resolve(work, n);
const host = {
  file: (a) => {
    const [sub, ...r] = a;
    const args = r.filter((x) => !x.startsWith("-") || x === "-");
    switch (sub) {
      case "exists": return fs.existsSync(W(args[0])) ? "1" : "0";
      case "delete": for (const f of args) fs.rmSync(W(f), { force: true, recursive: true }); return "";
      case "size": return String(fs.statSync(W(args[0])).size);
      case "join": return path.posix.join(...args);
      case "tail": return path.posix.basename(args[0]);
      case "dirname": return path.posix.dirname(args[0]);
      case "extension": return path.posix.extname(args[0]);
      case "rootname": return args[0].slice(0, args[0].length - path.posix.extname(args[0]).length);
      case "normalize": return path.resolve(work, args[0]);
      case "isdirectory": return fs.existsSync(W(args[0])) && fs.statSync(W(args[0])).isDirectory() ? "1" : "0";
      case "isfile": return fs.existsSync(W(args[0])) && fs.statSync(W(args[0])).isFile() ? "1" : "0";
      case "mkdir": for (const f of args) fs.mkdirSync(W(f), { recursive: true }); return "";
      case "copy": fs.copyFileSync(W(args[0]), W(args[1])); return "";
      case "rename": fs.renameSync(W(args[0]), W(args[1])); return "";
      case "split": return args[0].split("/").filter((x, i) => x || i === 0).map((x) => x || "/").map(quote).join(" ");
      case "attributes": case "readable": case "writable": return "1";
      case "nativename": return args[0];
      case "mtime": return String(Math.floor(fs.statSync(W(args[0])).mtimeMs / 1000));
      default: throw new Error(`file ${sub}: not in the spike host`);
    }
  },
  glob: (a) => {
    const pats = a.filter((x) => !x.startsWith("-"));
    const out = [];
    for (const pat of pats) {
      const re = new RegExp("^" + pat.replace(/[.+^${}()|\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, ".") + "$");
      for (const f of fs.readdirSync(W(path.posix.dirname(pat)))) {
        const full = path.posix.join(path.posix.dirname(pat), f).replace(/^\.\//, "");
        if (re.test(full) || re.test(f)) out.push(full);
      }
    }
    return out.map(quote).join(" ");
  },
  source: (a) => {
    const f = a[a.length - 1];
    const text = fs.readFileSync(fs.existsSync(f) ? f : W(f), "utf8");
    const r = zeval(text);
    if (r.code === 1) throw new Error(r.result);
    return r.result;
  },
  flush: () => "",
  fconfigure: () => "",
  exit: (a) => { finish(); process.exit(Number(a[0] || 0)); },
};

function cextCall(argc, argv) {
  depth++;
  try { return cextCallIn(argc, argv >>> 0); } finally { depth--; }
}
function cextCallIn(argc, argv) {
  const dvz = new DataView(Z.memory.buffer);
  const a = [];
  const tags = [];
  for (let i = 0; i < argc; i++) { a.push(zstr(dvz.getUint32(argv + 12 * i, true), dvz.getUint32(argv + 12 * i + 4, true))); tags.push(dvz.getUint32(argv + 12 * i + 8, true)); }
  const name = a[0].replace(/^::/, "");
  if (name === "__cext_call") {
    const c = cmds.get(Number(a[1]));
    if (!c) { zreply("deleted command"); return 1; }
    const rc = runCommand(c, a.slice(2), tags.slice(2));
    zreply(resultStr());
    return rc;
  }
  if (!host[name]) { zreply(`invalid command name "${a[0]}" (cext)`); return 1; }
  try { zreply(host[name](a.slice(1))); return 0; } catch (e) { if (process.env.CEXT_DEBUG) process.stderr.write(e.stack + "\n"); zreply(String(e.message)); return 1; }
}

function finish() {
  if (!M || !slotsOut) return;
  const cnt = new Uint32Array(M.memory.buffer, M.shim_cnt.value, 691);
  const lines = [];
  cnt.forEach((n, i) => { if (n) lines.push(`pub\t${i}\t${n}`); });
  fs.writeFileSync(slotsOut, lines.join("\n") + "\n");
}

// ---- Start ----
const zmod = new WebAssembly.Module(fs.readFileSync(ztclPath));
const zi = new WebAssembly.Instance(zmod, { ztcl_host: {
  output: (p, n) => process.stdout.write(zmem().slice(p, p + n)),
  dom: () => -1, zone: () => -1, now_ms: () => Date.now(), cext_call: cextCall,
} });
Z = zi.exports;
h = Z.ztcl_new();
Z.ztcl_clock_allow(h);
for (const n of [...Object.keys(host), "__cext_call"]) { const [p, k] = zput(n); Z.ztcl_cext_command(h, p, k); }

fs.mkdirSync(work, { recursive: true });
const wasi = new WASI({ version: "preview1", preopens: { "/": work }, returnOnExit: true });
const smod = new WebAssembly.Module(fs.readFileSync(sqlPath));
const tcl = {};
for (const im of WebAssembly.Module.imports(smod)) {
  if (im.module !== "tcl") continue;
  tcl[im.name] = T[im.name] || ((...a) => { throw new Error(`slot ${im.name}: not in the spike bridge`); });
}
const si = new WebAssembly.Instance(smod, { tcl, wasi_snapshot_preview1: wasi.wasiImport });
M = si.exports;
table = M.__indirect_function_table;
wasi.initialize(si);
for (const n of ["bytearray", "wideInt", "double", "list"]) {
  const p = M.malloc(24); u8().fill(0, p, p + 24); wr(p, cput(n)); types[n] = p;
}
interpPtr = M.malloc(64);
u8().fill(0, interpPtr, interpPtr + 64);
if (M.Sqlite3_Init(interpPtr) !== 0) throw new Error("Sqlite3_Init: " + resultStr());

zeval(`set ::spike ${quote(process.env.SPIKE || "")}; set ::shimdir ${quote(path.dirname(path.resolve(script)))}`);
zeval(`set argv0 ${quote(script)}; set argv ${quote(scriptArgs.map(quote).join(" "))}; set argc ${scriptArgs.length}`);
const t0 = performance.now();
const r = zeval(fs.readFileSync(script, "utf8"));
if (r.code === 1) process.stdout.write("ERROR: " + r.result + "\n");
process.stderr.write(`time ${(performance.now() - t0).toFixed(1)} ms, ztcl memory ${Z.memory.buffer.byteLength} bytes, module memory ${M.memory.buffer.byteLength} bytes, ${objs.size} objects\n`);
finish();
