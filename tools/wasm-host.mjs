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
  get parentNode() {
    return this.parent;
  }
  get isConnected() {
    let top = this;
    while (top.parent) top = top.parent;
    return top === page;
  }
  get ownerDocument() {
    return { createElement: (tag) => new El(tag) };
  }
  get classList() {
    const list = () => (this.attrs.class ?? "").split(" ").filter((c) => c);
    const put = (l) => (this.attrs.class = l.join(" "));
    return {
      add: (c) => list().includes(c) || put([...list(), c]),
      remove: (c) => put(list().filter((x) => x !== c)),
      toggle: (c) => (list().includes(c) ? (put(list().filter((x) => x !== c)), false) : (put([...list(), c]), true)),
      contains: (c) => list().includes(c),
    };
  }
  get style() {
    this.css ??= {};
    return { getPropertyValue: (p) => this.css[p] ?? "", setProperty: (p, v) => (this.css[p] = v) };
  }
  focus() {
    focused = this;
  }
  appendChild(k) {
    if (k.parent) k.remove();
    return this.add(k);
  }
  remove() {
    if (!this.parent) return;
    this.parent.kids = this.parent.kids.filter((k) => k !== this);
    this.parent = null;
  }
  get innerHTML() {
    return this.kids.map((k) => `<${k.tag}>${k.textContent}</${k.tag}>`).join("") || this.own;
  }
  set innerHTML(h) {
    this.own = h;
    this.kids = [];
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
  get nodeType() {
    return 1;
  }
  addEventListener(type, fn) {
    (this.on ??= {})[type] = fn;
  }
  removeEventListener(type, fn) {
    if (this.on?.[type] === fn) delete this.on[type];
  }
  // A DOM event of the test: it goes to the listeners of the element
  // and of each parent.
  fire(type, props = {}) {
    const ev = { type, target: this, ...props };
    for (let e = this; e; e = e.parent) e.on?.[type]?.(ev);
  }
}
const root = new El("div").add(new El("p", { id: "msg", class: "note" }, "hello"), new El("p", { class: "note" }, "second"));
const outside = new El("div").add(new El("p", { id: "secret" }, "outside"));
const page = new El("body").add(root, outside);
let focused = null;
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

// #85 task 02: classes, styles, form values, focus, new elements, and HTML.
ev("set m [dom query #msg]");
check(ev("dom class $m add big; dom class $m has big").result === "1", "dom class add and has");
check(ev("dom class $m toggle big").result === "0" && ev("dom class $m has big").result === "0", "dom class toggle");
ev("dom class $m remove note");
check(root.kids[0].attrs.class === "", "dom class remove");
check(!ev("dom class $m paint x").ok, "dom class with a bad action is an error");
ev("dom style $m color red");
check(ev("dom style $m color").result === "red", "dom style");
const input = new El("input", { id: "in" });
input.value = "typed";
const box = new El("input", { id: "box" });
box.type = "checkbox";
root.add(input, box);
check(ev("dom value [dom query #in]").result === "typed", "dom value of an input");
ev("dom value [dom query #in] new; dom value [dom query #box] 1");
check(input.value === "new" && box.checked === true, "dom value sets an input and a checkbox");
check(ev("dom value [dom query #box]").result === "1", "dom value of a checkbox");
ev("dom focus [dom query #in]");
check(focused === input, "dom focus");
const made = ev("set li [dom create li]; set b [dom create b]; dom text $b bold; dom append $li $b; dom text $li");
check(made.ok && made.result === "bold", `a new tree is in scope before dom append (got ${made.result})`);
const ul = new El("ul", { id: "list" });
root.add(ul);
ev("dom append [dom query #list] $li");
check(ul.kids[0]?.tag === "li" && ev("dom text [dom query li]").result === "bold", "dom append puts the tree below the root");
check(!ev("dom append $li {}").ok, "an element cannot go below itself");
for (const tag of ["script", "iframe", "object", "SCRIPT", "bad tag"]) check(!ev(`dom create {${tag}}`).ok, `dom create ${tag} is an error`);
for (const [n, v] of [["onclick", "x()"], ["ONload", "x()"], ["href", "javascript:x()"], ["href", " java\tscript:x()"], ["srcdoc", "<b>"]]) {
  check(!ev(`dom attr $m {${n}} {${v}}`).ok, `dom attr ${n}=${v} is an error`);
}
check(ev("dom attr $m href https://example.org").ok, "a plain href is allowed");
check(ev("dom html $li").result === "<b>bold</b>", "dom html reads the HTML");
check(!ev("dom html $li {<i>x</i>}").ok, "dom html set needs the grant dom-html");
ev("dom remove $li");
check(ul.kids.length === 0, "dom remove takes the element out");
check(!ev("dom text $li").ok && !ev("dom text $b").ok, "the handles of a removed tree are invalid");
d.close();
const dh = await Interp.create(host, { allow: ["dom", "dom-html"], domRoot: root });
const r3 = dh.eval("set e [dom create div]; dom html $e {<i>x</i>}; dom html $e");
check(r3.ok && r3.result === "<i>x</i>", `dom html with the grant dom-html (got ${r3.result})`);
dh.close();

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

// #26 task 04: events that the host runs.
const noEv = await Interp.create(host);
check(noEv.eval("info commands after").result === "", "after is absent by default");
noEv.close();
let evNow = 5000;
const ev4 = await Interp.create(host, { allow: ["event"], now: () => evNow });
check(ev4.eval("after 10 {set x 1}; after idle {lappend order idle}; info exists x").result === "0", "after 10 waits for the host");
evNow += 5;
check(ev4.runEvents().ok && ev4.eval("info exists x").result === "0", "the timer is not due after 5 ms");
check(ev4.eval("set order").result === "idle", "after idle runs at the first run of the events");
check(ev4.runEvents(evNow + 5).ok && ev4.eval("set x").result === "1", "after 10 runs after one runEvents 10 ms later");
const vw = ev4.eval("vwait y");
check(!vw.ok && vw.result.includes('"y"'), `vwait gives an error with the name (got ${vw.result})`);
check(!ev4.eval("after 5").ok, "after with no script gives an error");
check(ev4.eval("after 1 {set z 2}; update; info exists z").result === "0", "update runs the due events only");
ev4.close();
// The timer of setTimeout runs the events on the real clock.
const ev5 = await Interp.create(host, { allow: ["event"], onOutput: () => {} });
const ran = new Promise((resolve) => { ev5.onEvents = resolve; });
ev5.eval("after 20 {puts tick; set w 3}");
const r5 = await ran;
check(r5.ok && r5.output === "tick\n" && ev5.eval("set w").result === "3", `setTimeout runs the events (got ${JSON.stringify(r5)})`);
ev5.close();

// #85 task 03: `dom on` and `dom off`. The script of each event runs
// from runEvents with its own compute limit.
{
  const box = new El("div");
  const btn = new El("button", { id: "go" }, "Go");
  box.add(btn);
  const top = new El("div").add(box);
  const dq = await Interp.create(host, { allow: ["dom"], domRoot: top, domComputeLimit: 5000 });
  const evq = (s) => dq.eval(s);
  check(evq("set b [dom query #go]; set box [dom query div]; dom on $b click {lappend got [list %x %y %target 100%%]}; dom on $box keydown {lappend keys %key}").ok, "dom on adds a script");
  btn.fire("click", { clientX: 3, clientY: 4 });
  check(evq("info exists got").result === "0", "the script waits for runEvents");
  const r1 = dq.runEvents();
  check(r1.ok && evq("set got").result === `{3 4 ${evq("set b").result} 100%}`, `a click runs the script with the substitutions (got ${evq("set got").result})`);
  btn.fire("keydown", { key: "a b" });
  dq.runEvents();
  check(evq("set keys").result === "{a b}", `%key is one word (got ${evq("set keys").result})`);
  evq("dom off $b click");
  btn.fire("click", { clientX: 5, clientY: 6 });
  dq.runEvents();
  check(evq("llength $got").result === "1", "dom off ends the script");
  evq("dom on $b click {while 1 {}}");
  btn.fire("click", {});
  const r2 = dq.runEvents();
  check(!r2.ok && r2.result === "compute limit reached", `a callback stops at domComputeLimit (got ${r2.result})`);
  check(evq("expr {1 + 1}").result === "2", "the interpreter runs after a callback at its limit");
  check(!evq("dom on $b {bad name} {}").ok, "dom on checks the event name");
  // The timer of setTimeout runs the queue.
  evq("dom on $b click {set fired 1}");
  const done = new Promise((resolve) => { dq.onEvents = resolve; });
  btn.fire("click", {});
  const r3 = await done;
  check(r3.ok && evq("set fired").result === "1", "setTimeout runs the DOM events");
  evq("dom remove $b");
  check(!btn.on?.click, "dom remove ends the scripts of the element");
  dq.close();
}

if (failed) process.exit(1);
console.log("wasm host ok");
