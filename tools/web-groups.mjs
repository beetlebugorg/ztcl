// Tests the Tcl wrappers of the groups of web:: (src/web/*.tcl) in
// ztcl-host.wasm with fake device APIs, and runs the demo scripts of the
// playground against the fakes.
//
//   node tools/web-groups.mjs zig-out/lib/ztcl-host.wasm
//
// SPDX-License-Identifier: BSD-2-Clause
import { compile, Interp } from "../web/ztcl.mjs";
import * as web from "../web/ztcl-web.mjs";
import fs from "node:fs";

const [hostPath] = process.argv.slice(2);
let failed = 0;
const check = (ok, what) => {
  if (!ok) {
    console.error(`FAIL ${what}`);
    failed++;
  }
};
const host = await compile(hostPath);
const tick = () => new Promise((res) => setTimeout(res, 5));
const until = async (f) => {
  for (let i = 0; i < 50 && !f(); i++) await tick();
};
const domError = (name, message) => {
  const e = new Error(message);
  e.name = name;
  return e;
};
const playground = (name) => fs.readFileSync(new URL(`../docs/site/playground/${name}`, import.meta.url), "utf8");

// A fake element for `dom` of the demo scripts.
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

// Runs `script` and gives the output of `puts` and of the event scripts.
async function session(allow, webRoot, extra = {}) {
  const lines = [];
  const t = await Interp.create(host, {
    allow: ["event", ...allow],
    web,
    webRoot,
    onOutput: (s) => lines.push(s),
    onEvents: (r) => {
      if (!r.ok) lines.push(`bgerror: ${r.result}\n`);
    },
    ...extra,
  });
  return { t, lines, out: () => lines.join("") };
}

// ---- Bluetooth ----

const BT = "0000180d-0000-1000-8000-00805f9b34fb";
class BluetoothCharacteristicProperties {
  constructor(p) {
    for (const k of ["broadcast", "read", "writeWithoutResponse", "write", "notify", "indicate", "authenticatedSignedWrites", "reliableWrite", "writableAuxiliaries"]) this[k] = p.includes(k);
  }
}
class BluetoothRemoteGATTCharacteristic extends EventTarget {
  constructor(service, uuid, props) {
    super();
    Object.assign(this, { service, uuid, properties: new BluetoothCharacteristicProperties(props), value: null, written: [], notifying: false });
  }
  readValue() {
    this.value = new DataView(new Uint8Array([0x5a]).buffer);
    return Promise.resolve(this.value);
  }
  writeValue(v) {
    this.written.push(["any", Array.from(v)]);
    return Promise.resolve();
  }
  writeValueWithResponse(v) {
    this.written.push(["response", Array.from(v)]);
    return Promise.resolve();
  }
  writeValueWithoutResponse(v) {
    this.written.push(["none", Array.from(v)]);
    return Promise.resolve();
  }
  startNotifications() {
    this.notifying = true;
    return Promise.resolve(this);
  }
  stopNotifications() {
    this.notifying = false;
    return Promise.resolve(this);
  }
  // A notification of the device.
  send(bytes) {
    this.value = new DataView(new Uint8Array(bytes).buffer);
    this.dispatchEvent(new Event("characteristicvaluechanged"));
  }
}
class BluetoothRemoteGATTService extends EventTarget {
  constructor(device, uuid) {
    super();
    Object.assign(this, { device, uuid, isPrimary: true });
    this.chars = [new BluetoothRemoteGATTCharacteristic(this, "00002a37-0000-1000-8000-00805f9b34fb", ["notify"]), new BluetoothRemoteGATTCharacteristic(this, "00002a39-0000-1000-8000-00805f9b34fb", ["write"])];
  }
  getCharacteristic(id) {
    const c = this.chars.find((c) => c.uuid === id || (id === "heart_rate_measurement" && c.uuid.startsWith("00002a37")));
    return c ? Promise.resolve(c) : Promise.reject(domError("NotFoundError", `No Characteristics matching UUID ${id} found in Service.`));
  }
  getCharacteristics() {
    return Promise.resolve(this.chars);
  }
}
class BluetoothRemoteGATTServer {
  constructor(device) {
    Object.assign(this, { device, connected: false });
    this.svc = new BluetoothRemoteGATTService(device, BT);
  }
  connect() {
    this.connected = true;
    return Promise.resolve(this);
  }
  disconnect() {
    this.connected = false;
    this.device.dispatchEvent(new Event("gattserverdisconnected"));
  }
  getPrimaryService(id) {
    return id === BT || id === "heart_rate" ? Promise.resolve(this.svc) : Promise.reject(domError("NotFoundError", `No Services matching UUID ${id} found in Device.`));
  }
  getPrimaryServices() {
    return Promise.resolve([this.svc]);
  }
}
class BluetoothDevice extends EventTarget {
  constructor(name) {
    super();
    Object.assign(this, { id: "dev1", name });
    this.gatt = new BluetoothRemoteGATTServer(this);
  }
}
class Bluetooth extends EventTarget {
  constructor() {
    super();
    this.device = new BluetoothDevice("Polar H10");
    this.asked = [];
  }
  requestDevice(options) {
    this.asked.push(options);
    if (this.deny) return Promise.reject(domError("NotFoundError", "User cancelled the requestDevice() chooser."));
    return Promise.resolve(this.device);
  }
  getDevices() {
    return Promise.resolve([this.device]);
  }
  getAvailability() {
    return Promise.resolve(true);
  }
}

{
  const bt = new Bluetooth();
  const { t, out } = await session(["web:bluetooth"], { navigator: { bluetooth: bt } });
  const ev = (s) => t.eval(s);
  let r = ev("web::bluetooth::uuid 0x180d");
  check(r.ok && r.result === BT, `uuid of a number (got ${r.result})`);
  r = ev("web::bluetooth::uuid heart_rate");
  check(r.ok && r.result === "heart_rate", `uuid of a name (got ${r.result})`);
  r = ev("web::bluetooth::request -command puts");
  check(!r.ok && /give a filter/.test(r.result), `request with no filter (got ${r.result})`);
  r = ev("web::bluetooth::request -services heart_rate");
  check(!r.ok && /wrong # args/.test(r.result), `request with no -command (got ${r.result})`);
  r = ev("web::bluetooth::request -bogus 1 -command puts");
  check(!r.ok && /bad option "-bogus": must be -all, -command,/.test(r.result), `a bad option (got ${r.result})`);

  r = ev(`proc got {status dev} {set ::dev $dev; puts "$status [web::bluetooth::info $dev]"}
web::bluetooth::request -services {heart_rate 0x180f} -prefix Polar -optional battery_service -command got`);
  check(r.ok, `request (got ${r.result})`);
  await until(() => out().includes("ok"));
  check(JSON.stringify(bt.asked[0]) === JSON.stringify({ filters: [{ services: ["heart_rate", "0000180f-0000-1000-8000-00805f9b34fb"], namePrefix: "Polar" }], optionalServices: ["battery_service"] }), `request options (got ${JSON.stringify(bt.asked[0])})`);
  check(out() === "ok kind device id dev1 name {Polar H10} connected 0\n", `the device (got ${JSON.stringify(out())})`);

  ev("web::bluetooth::request -all 1 -command {apply {{s v} {}}}");
  check(bt.asked[1]?.acceptAllDevices === true, "request -all 1");

  r = ev(`web::bluetooth::ondisconnect $::dev {apply {{d} {puts "gone $d"}}}
web::bluetooth::connect $::dev -command {apply {{s d} {
    puts "connect $s [web::bluetooth::connected $d]"
    web::bluetooth::service $d 0x180d -command {apply {{s svc} {
        set ::svc $svc
        puts "service $s [dict get [web::bluetooth::info $svc] uuid]"
        web::bluetooth::characteristics $svc -command {apply {{s cs} {
            foreach c $cs {puts "char [dict get [web::bluetooth::info $c] properties]"}
            set ::hr [lindex $cs 0]
            set ::cp [lindex $cs 1]
        }}}
    }}}
}}}`);
  check(r.ok, `connect (got ${r.result})`);
  await until(() => out().includes("char write"));
  check(out().endsWith(`connect ok 1\nservice ok ${BT}\nchar notify\nchar write\n`), `GATT (got ${JSON.stringify(out())})`);

  const svc = bt.device.gatt.svc;
  r = ev(`web::bluetooth::notify $::hr {apply {{b} {binary scan $b cucu f v; puts "bpm $v"}}} -command {apply {{s v} {puts "notify $s"}}}`);
  check(r.ok, `notify (got ${r.result})`);
  await until(() => out().includes("notify ok"));
  check(svc.chars[0].notifying, "startNotifications");
  svc.chars[0].send([0, 72]);
  svc.chars[0].send([0, 75]);
  await until(() => out().includes("bpm 75"));
  check(out().includes("bpm 72\nbpm 75\n"), `notifications (got ${JSON.stringify(out())})`);
  ev("web::bluetooth::notify $::hr {}");
  await until(() => !svc.chars[0].notifying);
  svc.chars[0].send([0, 80]);
  await tick();
  check(!svc.chars[0].notifying && !out().includes("bpm 80"), "notify with an empty script ends the notifications");

  r = ev(`web::bluetooth::write $::cp \\x01 -command {apply {{s v} {puts "write $s {$v}"}}}
web::bluetooth::write $::cp \\x02 -response 0
web::bluetooth::write $::cp \\x03 -response yes`);
  check(r.ok, `write (got ${r.result})`);
  await until(() => svc.chars[1].written.length === 3);
  check(JSON.stringify(svc.chars[1].written) === JSON.stringify([["any", [1]], ["none", [2]], ["response", [3]]]), `the writes (got ${JSON.stringify(svc.chars[1].written)})`);
  r = ev("web::bluetooth::write $::cp x -response maybe");
  check(!r.ok && /expected boolean/.test(r.result), `write -response maybe (got ${r.result})`);
  r = ev("web::bluetooth::read $::hr -command {apply {{s v} {puts \"read $s [scan $v %c]\"}}}");
  await until(() => out().includes("read ok"));
  check(out().includes("read ok 90\n"), `read (got ${JSON.stringify(out())})`);

  // An error of the device goes to the script.
  ev("web::bluetooth::characteristic $::svc 0x2a00 -command {apply {{s v} {puts \"missing $s $v\"}}}");
  await until(() => out().includes("missing"));
  check(out().includes("missing error web: NotFoundError: No Characteristics matching UUID 00002a00-0000-1000-8000-00805f9b34fb found in Service."), `an error of the device (got ${JSON.stringify(out())})`);

  ev("web::bluetooth::disconnect $::dev");
  await until(() => out().includes("gone"));
  check(out().includes("gone web"), `ondisconnect (got ${JSON.stringify(out())})`);
  check(ev("web::bluetooth::connected $::dev").result === "0", "connected after disconnect");

  // A cancelled chooser.
  bt.deny = true;
  ev("web::bluetooth::request -name X -command {apply {{s v} {puts \"denied $s $v\"}}}");
  await until(() => out().includes("denied"));
  check(out().includes("denied error web: NotFoundError: User cancelled the requestDevice() chooser."), `a cancelled chooser (got ${JSON.stringify(out())})`);
  t.close();
}

// No Web Bluetooth in the browser, and no grant.
{
  const { t } = await session(["web:bluetooth"], { navigator: {} });
  const r = t.eval("web::bluetooth::devices -command puts");
  check(!r.ok && r.result === "web::bluetooth: this browser has no Web Bluetooth", `a browser without the API (got ${r.result})`);
  check(t.eval("set errorCode").result === "WEB UNSUPPORTED navigator.bluetooth", "the error code of a browser without the API");
  t.close();
  const s = await session(["web:serial"], { navigator: {} });
  const r2 = s.t.eval("web::bluetooth::devices -command puts");
  check(!r2.ok && /invalid command name/.test(r2.result), `no web::bluetooth without the grant (got ${r2.result})`);
  s.t.close();
}

// The heart-rate demo of the playground.
{
  const bt = new Bluetooth();
  const els = Object.fromEntries(["go", "stop", "bpm", "out"].map((id) => [id, new FakeEl(id)]));
  const app = new FakeEl("app", Object.values(els));
  const { t, out } = await session(["dom", "web:bluetooth"], { navigator: { bluetooth: bt } }, { domRoot: app });
  const r = t.eval(playground("bluetooth.tcl"));
  check(r.ok, `the Bluetooth demo script (got ${r.result})`);
  check(bt.asked.length === 0, "the demo asks for no device before a click");
  els.go.dispatchEvent(new Event("click"));
  const hr = bt.device.gatt.svc.chars[0];
  await until(() => hr.notifying);
  hr.send([1, 0x2c, 0x01]);
  await until(() => els.bpm.textContent === "300");
  hr.send([0, 61]);
  await until(() => els.bpm.textContent === "61");
  check(els.bpm.textContent === "61", `the demo rate (got ${els.bpm.textContent})`);
  els.stop.dispatchEvent(new Event("click"));
  await until(() => els.out.textContent.includes("disconnected"));
  check(els.out.textContent === "device: Polar H10\nnotifications on\ndisconnected\n", `the demo output (got ${JSON.stringify(els.out.textContent)} ${out()})`);
  t.close();
}

if (failed) {
  console.error(`${failed} failed`);
  process.exit(1);
}
console.log("web group tests pass");
