// Tests the commands `web::` of ztcl-host.wasm with a fake
// navigator.serial (docs/dev/web-api-tasks/README.md).
//
//   node tools/web-api.mjs zig-out/lib/ztcl.wasm zig-out/lib/ztcl-host.wasm
//
// SPDX-License-Identifier: BSD-2-Clause
import { compile, Interp } from "../web/ztcl.mjs";
import * as web from "../web/ztcl-web.mjs";

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
r = ev("web::root navigator.usb");
check(!r.ok && /no root "navigator.usb"/.test(r.result), `an unknown root (got ${r.result})`);

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

if (failed) {
  console.error(`${failed} failed`);
  process.exit(1);
}
console.log("web API tests pass");
