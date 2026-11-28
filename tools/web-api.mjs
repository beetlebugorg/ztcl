// Tests the commands `web::` of ztcl-host.wasm with a fake
// navigator.serial (docs/dev/web-api-tasks/README.md).
//
//   node tools/web-api.mjs zig-out/lib/ztcl.wasm zig-out/lib/ztcl-host.wasm
//
// SPDX-License-Identifier: BSD-2-Clause
import { compile, Interp } from "../web/ztcl.mjs";
import * as web from "../web/ztcl-web.mjs";
import fs from "node:fs";

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

class SerialPort extends EventTarget {
  constructor(info) {
    super();
    this.info = info;
    this.connected = true;
    this.opened = null;
  }
  getInfo() {
    return this.info;
  }
  open(options) {
    this.opened = options;
    return Promise.resolve();
  }
}
class Serial extends EventTarget {
  constructor() {
    super();
    this.ports = [new SerialPort({ usbVendorId: 0x2341, usbProductId: 0x0043 })];
  }
  getPorts() {
    return Promise.resolve(this.ports);
  }
}
const serial = new Serial();
const webRoot = { navigator: { serial } };

// The bridge is absent by default and in ztcl.wasm.
check(!WebAssembly.Module.exports(strict).some((e) => e.name.startsWith("ztcl_web")), "ztcl.wasm has no ztcl_web exports");
let t = await Interp.create(host, { webRoot });
let r = t.eval("web::root navigator.serial");
check(!r.ok && /invalid command name/.test(r.result), `no web:: without a grant (got ${r.result})`);
t.close();
let threw = "";
try {
  await Interp.create(strict, { allow: ["web:serial"], web, webRoot });
} catch (e) {
  threw = e.message;
}
check(/no Web API bridge/.test(threw), `ztcl.wasm refuses web:serial (got ${threw})`);
threw = "";
try {
  await Interp.create(host, { allow: ["web:serial"], webRoot });
} catch (e) {
  threw = e.message;
}
check(/give the module ztcl-web.mjs/.test(threw), `a group needs the option web (got ${threw})`);

// A group that the page did not grant.
t = await Interp.create(host, { allow: ["web:usb"], web, webRoot });
r = t.eval("web::root navigator.serial");
check(!r.ok && r.result === 'web: the group "serial" is not allowed', `an ungranted group (got ${r.result})`);
t.close();

t = await Interp.create(host, { allow: ["web:serial"], web, webRoot });
const ev = (s) => t.eval(s);
r = ev("set s [web::root navigator.serial]");
check(r.ok && r.result === "web1", `web::root (got ${r.result})`);
check(ev("web::root navigator.serial").result === "web1", "the same object gives the same handle");
r = ev("web::root navigator.secret");
check(!r.ok && /no root "navigator.secret"/.test(r.result), `an unknown root (got ${r.result})`);
r = ev("web::root navigator.usb");
check(!r.ok && r.result === 'web: the group "usb" is not allowed', `a root of an ungranted group (got ${r.result})`);

// A member out of the table.
r = ev("web::get $s secret");
check(!r.ok && r.result === 'web: the interface "Serial" has no attribute "secret"', `an attribute out of the table (got ${r.result})`);
r = ev("web::call $s eval 1");
check(!r.ok && r.result === 'web: the interface "Serial" has no method "eval"', `a method out of the table (got ${r.result})`);
r = ev("web::call $s getPorts");
check(!r.ok && /gives a promise: use -command/.test(r.result), `a promise without -command (got ${r.result})`);
r = ev("web::get $s onconnect");
check(!r.ok && /use web::on/.test(r.result), `an event handler (got ${r.result})`);

// Values by type: a handle, a dictionary, a boolean, a read-only attribute.
const p = t._web.wrap(serial.ports[0], "SerialPort");
check(p === "web2", `a port handle (got ${p})`);
r = ev(`web::call ${p} getInfo`);
check(r.ok && r.result === "usbVendorId 9025 usbProductId 67", `a dictionary (got ${r.result})`);
r = ev(`web::get ${p} connected`);
check(r.ok && r.result === "1", `a boolean (got ${r.result})`);
r = ev(`web::set ${p} connected 0`);
check(!r.ok && /read-only/.test(r.result), `a read-only attribute (got ${r.result})`);
r = ev(`web::call ${p} getInfo extra`);
check(!r.ok && /wrong # args/.test(r.result), `too many arguments (got ${r.result})`);
r = ev(`web::call $s getInfo`);
check(!r.ok && /has no method "getInfo"/.test(r.result), `a method of another interface (got ${r.result})`);

// A throw of the page is a Tcl error with its name and message.
serial.ports[0].getInfo = () => {
  const e = new Error("No port selected by the user.");
  e.name = "NotFoundError";
  throw e;
};
r = ev(`web::call ${p} getInfo`);
check(!r.ok && r.result === "web: NotFoundError: No port selected by the user.", `an error of the page (got ${r.result})`);

// The conversion of the arguments, by the private toJS of the bridge.
const b = t._web;
const same = (a, e) => JSON.stringify(a) === JSON.stringify(e);
check(same(b.toJS("SerialOptions", "baudRate 115200 parity even"), { baudRate: 115200, parity: "even" }), "a dictionary argument");
const err = (f) => {
  try {
    f();
  } catch (e) {
    return e.message;
  }
  return "";
};
check(/required/.test(err(() => b.toJS("SerialOptions", "parity none"))), "a required member");
check(/bad value "mark"/.test(err(() => b.toJS("SerialOptions", "baudRate 9600 parity mark"))), "an enum");
check(/out of the range/.test(err(() => b.toJS("SerialOptions", "baudRate -1"))), "an integer range");
check(same(b.toJS("SerialPortRequestOptions", "filters {{usbVendorId 9025}}"), { filters: [{ usbVendorId: 9025 }] }), "a sequence of dictionaries");
check(same(Array.from(b.toJS("BufferSource", "M115\n")), [77, 49, 49, 53, 10]), "bytes");
check(b.fromJS("BufferSource", new Uint8Array([0, 200, 65])) === "\u0000ÈA", "bytes to Tcl");

// Each command of web:: costs one compute unit.
t.computeLimit = 5000;
r = ev("while 1 {web::get web2 connected}");
check(!r.ok && /compute limit/.test(r.result), `the compute limit stops the calls (got ${r.result})`);
t.computeLimit = null;

// web::release ends the handle.
r = ev(`web::release ${p}; web::get ${p} connected`);
check(!r.ok && r.result === `invalid web handle "${p}"`, `a released handle (got ${r.result})`);
r = ev("web::get web99 connected");
check(!r.ok && r.result === 'invalid web handle "web99"', `an unknown handle (got ${r.result})`);
t.close();

// Task 02: promises. The script of -command runs from runEvents with
// "ok" and the value, or "error" and the message.
const runs = [];
t = await Interp.create(host, { allow: ["web:serial"], web, webRoot, onEvents: (r) => runs.push(r) });
const tick = () => new Promise((res) => setTimeout(res, 5));
// Waits until cond() is true, for at most 10 s. A host under load can
// run the promises and the timers of the page late, so a check waits for
// its event, not for a fixed time. A timeout fails in the next check.
const until = async (cond, ms = 10000) => {
  const end = Date.now() + ms;
  while (!cond() && Date.now() < end) await tick();
};
r = t.eval(`set s [web::root navigator.serial]
proc got {what status value} {lappend ::got $what $status $value}
web::call $s getPorts -command {got ports}`);
check(r.ok && r.result === "", `-command gives an empty result (got ${r.result})`);
await until(() => runs.length >= 1);
r = t.eval("set got");
check(r.ok && r.result === "ports ok web2", `a promise that resolves (got ${r.result})`);
check(runs.length === 1 && runs[0].ok, "onEvents gets the run");
serial.requestPort = () => {
  const e = new Error("No port selected by the user.");
  e.name = "NotFoundError";
  return Promise.reject(e);
};
t.eval("set got {}; web::call $s requestPort {filters {{usbVendorId 9025}}} -command {got req}");
await until(() => runs.length >= 2);
r = t.eval("set got");
check(r.ok && r.result === "req error {web: NotFoundError: No port selected by the user.}", `a promise that rejects (got ${r.result})`);
r = t.eval("web::call web2 getInfo -command {got x}");
check(!r.ok && /gives no promise/.test(r.result), `-command for a method with no promise (got ${r.result})`);
r = t.eval("web::call $s requestPort {filters {{usbVendorId x}}} -command {got req}");
check(!r.ok && /expected integer/.test(r.result), `a bad argument fails at the call (got ${r.result})`);
// Each script has its own compute limit.
t.webComputeLimit = 1000;
t.eval("web::call $s getPorts -command {apply {args {while 1 {}}}}");
await until(() => runs.length >= 3);
check(runs.length === 3 && !runs[2].ok && /compute limit/.test(runs[2].result), `the compute limit of a script (got ${JSON.stringify(runs[2])})`);
r = t.eval("set got");
check(r.ok, "the interpreter runs after the limit");
t.close();

// Task 03: web::on and web::off with %type, %target, and %detail.
t = await Interp.create(host, { allow: ["web:serial"], web, webRoot });
t.eval("set s [web::root navigator.serial]; set seen {}");
r = t.eval("web::on $s connect {lappend ::seen %type %target [web::get %target connected] %detail}");
check(r.ok, `web::on (got ${r.result})`);
const port2 = new SerialPort({ usbVendorId: 1 });
const connect = (detail) => {
  const e = new CustomEvent("connect", { detail });
  Object.defineProperty(e, "target", { value: port2 });
  serial.dispatchEvent(e);
};
connect(7);
await until(() => t.eval("set seen").result !== "");
r = t.eval("set seen");
check(r.ok && r.result === "connect web2 1 7", `a connect event (got ${r.result})`);
r = t.eval("web::on $s message {puts x}");
check(!r.ok && /has no attribute "onmessage"/.test(r.result), `an event out of the table (got ${r.result})`);
r = t.eval("web::on $s connected {puts x}");
check(!r.ok, `a bad event name (got ${r.result})`);
t.eval("web::off $s connect");
connect(8);
await tick();
r = t.eval("set seen");
check(r.result === "connect web2 1 7", `no script after web::off (got ${r.result})`);
t.eval("web::on $s connect {lappend ::seen again}; web::release $s");
connect(9);
await tick();
check(t.eval("set seen").result === "connect web2 1 7", "no script after web::release");
t.close();
t = await Interp.create(host, { allow: ["web:usb"], web, webRoot });
r = t.eval("web::on web1 connect {}");
check(!r.ok && /invalid web handle/.test(r.result), `web::on of an unknown handle (got ${r.result})`);
t.close();

// Task 04: the generated table has the groups of the first table. A
// member of a partial Navigator has the group of its spec.
const gp = { id: "pad", index: 0, connected: true, axes: [0, 0.5], buttons: [] };
const nav = { serial, getGamepads: () => [gp, null] };
t = await Interp.create(host, { allow: ["web:serial"], web, webRoot: { navigator: nav } });
r = t.eval("web::call [web::root navigator] getGamepads");
check(!r.ok && r.result === 'web: the group "gamepad" is not allowed', `a Navigator member of an ungranted group (got ${r.result})`);
t.close();
t = await Interp.create(host, { allow: ["web:gamepad"], web, webRoot: { navigator: nav } });
r = t.eval("set pads [web::call [web::root navigator] getGamepads]; list [web::get [lindex $pads 0] id] [web::get [lindex $pads 0] axes] [lindex $pads 1]");
check(r.ok && r.result === "pad {0 0.5} {}", `getGamepads (got ${r.result})`);
t.close();
const { interfaces, roots } = await import("../web/webidl-table.mjs");
const groups = new Set(Object.values(interfaces).map((i) => i.group));
for (const g of ["serial", "usb", "bluetooth", "hid", "midi", "gamepad"]) check(groups.has(g), `the table has the group ${g}`);
check(roots["navigator.serial"] === "Serial" && roots["navigator.usb"] === "USB", "the roots of Navigator");

// Task 06: Web Serial as a channel. A fake port answers M115 as a 3D
// printer does. The script is the one of the PTY test in
// src/serial_tests.zig.
class FakePort extends SerialPort {
  constructor() {
    super({ usbVendorId: 0x2341 });
    this.written = "";
    this.readable = null;
    this.writable = null;
  }
  open(options) {
    this.opened = options;
    let ctl;
    this.readable = new ReadableStream({ start: (c) => (ctl = c) });
    this.writable = new WritableStream({
      write: (chunk) => {
        this.written += new TextDecoder().decode(chunk);
        if (this.written.endsWith("M115\n")) {
          // The reply comes in two chunks, with a line split between them.
          ctl.enqueue(new TextEncoder().encode("FIRMWARE_NAME:Mar"));
          setTimeout(() => ctl.enqueue(new TextEncoder().encode("lin 2.1.2\r\nok\r\n")), 2);
        }
      },
    });
    return Promise.resolve();
  }
  close() {
    this.closed = true;
    return Promise.resolve();
  }
}
const printer = new FakePort();
const serial2 = new Serial();
serial2.ports = [printer];
serial2.requestPort = () => Promise.resolve(printer);
const m115 = fs.readFileSync(new URL("../src/serial_testdata/m115.tcl", import.meta.url), "utf8");
t = await Interp.create(host, { allow: ["web:serial", "event"], web, webRoot: { navigator: { serial: serial2 } } });
r = t.eval(m115 + "\nweb::serial::request -filters {{usbVendorId 9025}} -command {apply {{status name} {set ::port $name}}}");
check(r.ok, `web::serial::request (got ${r.result})`);
await until(() => t.eval("info exists ::port").result === "1");
r = t.eval("set f [open $::port r+]; m115 $f; set f");
check(r.ok && r.result === "serial0", `open of the port (got ${r.result})`);
await until(() => t.eval("set ::done").result !== "0");
r = t.eval("list $::done $::reply [fconfigure $f -mode]");
check(r.ok && r.result === "1 {{FIRMWARE_NAME:Marlin 2.1.2} ok} 115200,n,8,1", `the M115 reply (got ${r.result})`);
check(printer.written === "M115\n" && printer.opened.baudRate === 115200 && printer.opened.parity === "none", `the write and the open options (got ${JSON.stringify([printer.written, printer.opened])})`);
r = t.eval("catch {fconfigure $f -mode 9600,m,8,1} m; set m");
check(r.result === "bad value for -mode parity: Web Serial has no mark or space parity", `mark parity (got ${r.result})`);
r = t.eval("catch {open $::port r+} m; set m");
check(/the port is open/.test(r.result), `a second open (got ${r.result})`);
r = t.eval("close $f");
await until(() => printer.closed);
check(r.ok && printer.closed, "close closes the port");
r = t.eval("web::serial::ports -command {apply {{status names} {set ::names $names}}}");
await until(() => t.eval("info exists ::names").result === "1");
check(t.eval("set ::names").result === "webserial1", `web::serial::ports (got ${t.eval("set ::names").result})`);
t.close();
t = await Interp.create(host, { allow: ["web:usb"], web, webRoot: { navigator: { serial: serial2 } } });
check(!t.eval("web::serial::request -command x").ok, "no web::serial without web:serial");
t.close();

// Task 07: the script of the demo page docs/site/playground/serial.html
// with a small fake DOM: a click, the port chooser, M115, and the reply.
class FakeEl extends EventTarget {
  constructor(id, kids = []) {
    super();
    Object.assign(this, { id, kids, parentNode: null, nodeType: 1, textContent: "", value: "" });
    for (const k of kids) k.parentNode = this;
  }
  contains(e) {
    for (; e; e = e.parentNode) if (e === this) return true;
    return false;
  }
  querySelector(sel) {
    for (const k of this.kids) {
      if (`#${k.id}` === sel) return k;
      const d = k.querySelector(sel);
      if (d) return d;
    }
    return null;
  }
}
const page = fs.readFileSync(new URL("../docs/site/playground/serial.html", import.meta.url), "utf8");
const demo = /const script = `([\s\S]*?)`;/.exec(page)[1].replace(/\\\\/g, "\\");
const out = new FakeEl("out");
const baud = new FakeEl("baud");
baud.value = "250000";
const go = new FakeEl("go");
const app = new FakeEl("app", [baud, go, out]);
const printer2 = new FakePort();
const serial3 = new Serial();
serial3.requestPort = () => Promise.resolve(printer2);
t = await Interp.create(host, { allow: ["dom", "event", "web:serial"], web, domRoot: app, webRoot: { navigator: { serial: serial3 } } });
r = t.eval(demo);
check(r.ok, `the demo script (got ${r.result})`);
go.dispatchEvent(new Event("click"));
await until(() => out.textContent.includes("ok") && printer2.closed);
check(out.textContent === "> M115\nFIRMWARE_NAME:Marlin 2.1.2\nok\n", `the demo output (got ${JSON.stringify(out.textContent)})`);
check(printer2.opened?.baudRate === 250000 && printer2.closed, "the demo opens at the baud of the page and closes the port");
t.close();

if (failed) {
  console.error(`${failed} failed`);
  process.exit(1);
}
console.log("web API tests pass");
