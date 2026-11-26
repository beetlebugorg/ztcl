// Tests ztcl-host.wasm, the form with the imports of `ztcl_host`, against
// ztcl.wasm (docs/dev/wasm-host-tasks/README.md).
//
//   node tools/wasm-host.mjs zig-out/lib/ztcl.wasm zig-out/lib/ztcl-host.wasm
//
// SPDX-License-Identifier: BSD-2-Clause
import { compile, Interp } from "../web/ztcl.mjs";

const [strictPath, hostPath] = process.argv.slice(2);
let failed = 0;
const check = (ok, what) => {
  if (!ok) {
    console.error(`FAIL ${what}`);
    failed++;
  }
};
const strict = await compile(strictPath);
const host = await compile(hostPath);
check(WebAssembly.Module.imports(strict).length === 0, "ztcl.wasm has no imports");
check(WebAssembly.Module.imports(host).every((i) => i.module === "ztcl_host"), "ztcl-host.wasm imports only ztcl_host");

// Task 02: each puts reaches onOutput at the time of the call, in order.
const seen = [];
const tcl = await Interp.create(host, { onOutput: (t) => seen.push(t) });
const r = tcl.eval("puts a; puts b; puts c; set x done");
check(r.ok && r.result === "done", "eval with live output");
check(seen.length === 3 && seen.join("") === "a\nb\nc\n", `three live calls in order (got ${JSON.stringify(seen)})`);
check(r.output === "a\nb\nc\n", "the output of the eval has the live text");
tcl.close();

// The compute limit stops a loop that writes at the same point in each form.
const stop = async (mod) => {
  const t = await Interp.create(mod, { computeLimit: 5000, onOutput: () => {} });
  t.eval("set i 0; while 1 {puts $i; incr i}");
  t.computeLimit = null;
  const i = t.eval("set i").result;
  t.close();
  return i;
};
const a = await stop(strict);
const b = await stop(host);
check(a === b, `the compute limit stops at ${a} in ztcl.wasm and at ${b} in ztcl-host.wasm`);

// #85 task 01: `dom` with a small DOM of plain objects. A selector is
// `#id`, `.class`, or a tag name.
class El {
  constructor(tag, attrs = {}, text = "") {
    Object.assign(this, { tag, attrs: { ...attrs }, kids: [], parent: null, own: text });
  }
  add(...kids) {
    for (const k of kids) {
      k.parent = this;
      this.kids.push(k);
    }
    return this;
  }
  get textContent() {
    return this.own + this.kids.map((k) => k.textContent).join("");
  }
  set textContent(t) {
    this.own = t;
    this.kids = [];
  }
  getAttribute(n) {
    return n in this.attrs ? this.attrs[n] : null;
  }
  setAttribute(n, v) {
    this.attrs[n] = v;
  }
  contains(e) {
    for (; e; e = e.parent) if (e === this) return true;
    return false;
  }
  matches(sel) {
    if (sel[0] === "#") return this.attrs.id === sel.slice(1);
    if (sel[0] === ".") return (this.attrs.class ?? "").split(" ").includes(sel.slice(1));
    return this.tag === sel;
  }
  querySelectorAll(sel) {
    const out = [];
    const walk = (e) => e.kids.forEach((k) => (k.matches(sel) && out.push(k), walk(k)));
    walk(this);
    return out;
  }
  querySelector(sel) {
    return this.querySelectorAll(sel)[0] ?? null;
  }
}
const root = new El("div").add(new El("p", { id: "msg", class: "note" }, "hello"), new El("p", { class: "note" }, "second"));
const outside = new El("div").add(new El("p", { id: "secret" }, "outside"));
void outside;

const plain = await Interp.create(host);
check(plain.eval("info commands dom").result === "", "dom is absent by default in ztcl-host.wasm");
plain.close();
let threw = false;
try {
  await Interp.create(strict, { allow: ["dom"], domRoot: root });
} catch {
  threw = true;
}
check(threw, "ztcl.wasm has no dom");

const d = await Interp.create(host, { allow: ["dom"], domRoot: root });
const ev = (s) => d.eval(s);
check(ev("set m [dom query #msg]; dom text $m").result === "hello", "dom query and dom text");
check(ev("llength [dom queryAll .note]").result === "2", "dom queryAll");
check(ev("dom attr $m class").result === "note", "dom attr");
check(ev("dom attr $m title").result === "", "dom attr of an absent attribute");
ev("dom attr $m title Hi; dom text $m changed");
check(root.kids[0].attrs.title === "Hi" && root.kids[0].textContent === "changed", "dom attr and dom text set the element");
check(ev("dom query #secret").result === "", "a query does not leave the root");
check(ev("dom text").ok === false, "dom text needs an element");
// An element that leaves the root is an invalid handle.
const second = ev("lindex [dom queryAll .note] 1").result;
root.kids.pop().parent = null;
const r2 = ev(`dom text ${second}`);
check(!r2.ok && r2.result === `invalid DOM handle "${second}"`, `a handle outside the root is an error (got ${r2.result})`);
check(!ev("dom text dom99").ok, "an unknown handle is an error");
d.close();

// #26 task 03: `clock` follows the clock of the host.
const noClock = await Interp.create(host);
check(noClock.eval("info commands clock").result === "", "clock is absent by default");
noClock.close();
let fake = 1700000000123;
const c = await Interp.create(host, { allow: ["clock"], now: () => fake });
check(c.eval("clock milliseconds").result === "1700000000123", "clock milliseconds follows the host");
fake += 2500;
check(c.eval("clock seconds").result === "1700000002", "clock seconds follows the host");
check(c.eval("clock format 0 -format %Y -gmt 1").result === "1970", "clock format in UTC");
c.close();
// A zone comes from the host as TZif bytes. The check needs the zone
// files of the system.
const { existsSync, readFileSync } = await import("node:fs");
if (existsSync("/usr/share/zoneinfo/America/New_York")) {
  const z = await Interp.create(host, { allow: ["clock"], zone: (name) => readFileSync(`/usr/share/zoneinfo/${name}`) });
  const r = z.eval("clock format 0 -format %H -timezone :America/New_York");
  check(r.ok && r.result === "19", `a zone of the host (got ${r.result})`);
  z.close();
} else console.log("SKIP: no /usr/share/zoneinfo");

if (failed) process.exit(1);
console.log("wasm host ok");
