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

// ---- Gamepad ----

class GamepadButton {
  constructor(v) {
    Object.assign(this, { value: v, pressed: v > 0.5, touched: v > 0 });
  }
}
class GamepadHapticActuator {
  constructor() {
    this.effects = ["dual-rumble"];
    this.played = [];
  }
  playEffect(type, params) {
    this.played.push([type, params]);
    return Promise.resolve("complete");
  }
}
const actuator = new GamepadHapticActuator();
// A new object for each read, as Chrome gives.
class Gamepad {
  constructor(index, axes, buttons) {
    Object.assign(this, { id: "Fake Pad (STANDARD GAMEPAD)", index, connected: true, timestamp: 12.5, mapping: "standard", axes, buttons: buttons.map((v) => new GamepadButton(v)), touches: [], vibrationActuator: actuator });
  }
}
class GamepadEvent extends Event {
  constructor(type, gamepad) {
    super(type);
    this.gamepad = gamepad;
  }
}
class Window extends EventTarget {}
function padRoot() {
  const w = new Window();
  w.pad = { axes: [0.5, -1], buttons: [1, 0, 0.25] };
  w.navigator = { getGamepads: () => [null, w.pad ? new Gamepad(1, w.pad.axes, w.pad.buttons) : null, null, null] };
  return w;
}

{
  const w = padRoot();
  const { t, out } = await session(["web:gamepad"], w);
  const ev = (s) => t.eval(s);
  let r = ev("web::gamepad::list");
  check(r.ok && r.result === "1", `list (got ${r.result})`);
  r = ev("web::gamepad::state 1");
  check(r.ok && r.result === "index 1 id {Fake Pad (STANDARD GAMEPAD)} mapping standard connected 1 timestamp 12.5 axes {0.5 -1} buttons {1 0 0.25} pressed {1 0 0}", `state (got ${r.result})`);
  r = ev("llength [web::gamepad::state]");
  check(r.ok && r.result === "1", `state of each pad (got ${r.result})`);
  r = ev("web::gamepad::state 0");
  check(!r.ok && r.result === "web::gamepad: no pad 0", `state of a free slot (got ${r.result})`);
  // The commands release each handle that they read.
  const before = t._web.objs.size;
  ev("web::gamepad::state 1; web::gamepad::list");
  check(t._web.objs.size === before, `no handles stay after state (got ${t._web.objs.size - before} more)`);

  r = ev("web::gamepad::onconnect {apply {{i id} {puts \"connect $i $id\"}}}; web::gamepad::ondisconnect {apply {{i id} {puts \"gone $i\"}}}");
  check(r.ok, `onconnect (got ${r.result})`);
  const withWindow = t._web.objs.size;
  w.dispatchEvent(new GamepadEvent("gamepadconnected", new Gamepad(1, [0, 0], [])));
  w.dispatchEvent(new GamepadEvent("gamepaddisconnected", new Gamepad(1, [0, 0], [])));
  await until(() => out().includes("gone"));
  check(out() === "connect 1 Fake Pad (STANDARD GAMEPAD)\ngone 1\n", `connect events (got ${JSON.stringify(out())})`);
  check(t._web.objs.size === withWindow, `no handles stay after the events (got ${t._web.objs.size - withWindow} more)`);
  ev("web::gamepad::ondisconnect {}");

  r = ev("web::gamepad::poll -command {}");
  check(r.ok, `poll with an empty script and no poll (got ${r.result})`);
  r = ev("set n 0; web::gamepad::poll -interval 5 -command {apply {{pads} {incr ::n; set ::last [lindex [dict get [lindex $pads 0] axes] 0]}}}");
  check(r.ok, `poll (got ${r.result})`);
  await until(() => Number(ev("set n").result) >= 3);
  w.pad.axes = [-0.25, 0];
  await until(() => ev("set last").result === "-0.25");
  check(ev("set last").result === "-0.25", `poll sees a new state (got ${ev("set last").result})`);
  ev("web::gamepad::poll -command {}");
  const n = ev("set n").result;
  await new Promise((res) => setTimeout(res, 40));
  check(ev("set n").result === n, "poll with an empty script stops");
  r = ev("web::gamepad::poll -interval 0 -command puts");
  check(!r.ok && /positive integer/.test(r.result), `poll -interval 0 (got ${r.result})`);

  r = ev("web::gamepad::rumble 1 -duration 300 -strong 0.5 -command {apply {{s v} {puts \"rumble $s $v\"}}}");
  check(r.ok, `rumble (got ${r.result})`);
  await until(() => out().includes("rumble"));
  check(out().includes("rumble ok complete") && JSON.stringify(actuator.played[0]) === JSON.stringify(["dual-rumble", { duration: 300, strongMagnitude: 0.5, weakMagnitude: 1 }]), `rumble effect (got ${JSON.stringify(actuator.played)})`);
  t.close();
}

// The gamepad without the event loop, and a browser without the API.
{
  const { t } = await session([], padRoot(), { allow: ["web:gamepad"] });
  let r = t.eval("web::gamepad::poll -command puts");
  check(!r.ok && /no event loop: grant "event"/.test(r.result), `poll without event (got ${r.result})`);
  t.close();
  const s = await session(["web:gamepad"], { navigator: {} });
  r = s.t.eval("web::gamepad::list");
  check(!r.ok && r.result === "web::gamepad: this browser has no Gamepad API", `a browser without the Gamepad API (got ${r.result})`);
  s.t.close();
}

// The gamepad demo of the playground.
{
  const w = padRoot();
  w.pad.axes = [1, 0];
  const els = Object.fromEntries(["go", "stop", "ball", "buttons", "out"].map((id) => [id, new FakeEl(id)]));
  for (const e of Object.values(els)) e.style = { props: {}, setProperty(k, v) { this.props[k] = v; }, getPropertyValue(k) { return this.props[k] ?? ""; } };
  const app = new FakeEl("app", Object.values(els));
  const { t, out } = await session(["dom", "web:gamepad"], w, { domRoot: app });
  const r = t.eval(playground("gamepad.tcl"));
  check(r.ok, `the gamepad demo script (got ${r.result})`);
  els.go.dispatchEvent(new Event("click"));
  await until(() => parseFloat(els.ball.style.props.left) >= 60);
  check(parseFloat(els.ball.style.props.left) >= 60 && els.ball.style.props.top === "50.0%", `the stick moves the ball (got ${JSON.stringify(els.ball.style.props)})`);
  check(els.buttons.textContent === "0" && els.ball.style.props.scale === "2", `the buttons (got ${els.buttons.textContent} ${els.ball.style.props.scale})`);
  els.stop.dispatchEvent(new Event("click"));
  await tick();
  const left = els.ball.style.props.left;
  await new Promise((res) => setTimeout(res, 60));
  check(els.ball.style.props.left === left, `stop ends the poll (got ${left} then ${els.ball.style.props.left}) ${out()}`);
  t.close();
}

// ---- MIDI ----

class MIDIInputMap extends Map {}
class MIDIOutputMap extends Map {}
class MIDIInput extends EventTarget {
  constructor(id, name) {
    super();
    Object.assign(this, { id, name, manufacturer: "Fake", type: "input", version: "1.0", state: "connected", connection: "closed" });
  }
  open() {
    this.connection = "open";
    return Promise.resolve(this);
  }
  // A message of the device.
  play(bytes) {
    const e = new MIDIMessageEvent("midimessage", new Uint8Array(bytes));
    this.dispatchEvent(e);
  }
}
class MIDIOutput extends EventTarget {
  constructor(id, name) {
    super();
    Object.assign(this, { id, name, manufacturer: "Fake", type: "output", version: "1.0", state: "connected", connection: "closed", sent: [] });
  }
  send(data, at) {
    this.sent.push(at === undefined ? Array.from(data) : [Array.from(data), at]);
  }
}
class MIDIMessageEvent extends Event {
  constructor(type, data) {
    super(type);
    this.data = data;
  }
}
class MIDIConnectionEvent extends Event {
  constructor(type, port) {
    super(type);
    this.port = port;
  }
}
class MIDIAccess extends EventTarget {
  constructor() {
    super();
    this.inputs = new MIDIInputMap([["in1", new MIDIInput("in1", "Keys")]]);
    this.outputs = new MIDIOutputMap([["out1", new MIDIOutput("out1", "Synth")]]);
    this.sysexEnabled = false;
  }
}
function midiRoot(deny = false) {
  const access = new MIDIAccess();
  const asked = [];
  return {
    access,
    asked,
    root: { navigator: { requestMIDIAccess: (o) => (asked.push(o), deny ? Promise.reject(domError("NotAllowedError", "Permission denied.")) : Promise.resolve(access)) } },
  };
}

{
  const m = midiRoot();
  const { t, out } = await session(["web:midi"], m.root);
  const ev = (s) => t.eval(s);
  let r = ev("web::midi::inputs");
  check(!r.ok && r.result === "web::midi: no MIDI access: call web::midi::request first", `inputs before request (got ${r.result})`);
  r = ev("web::midi::request -sysex 1 -command {apply {{s v} {puts \"request $s {$v}\"}}}");
  check(r.ok, `request (got ${r.result})`);
  await until(() => out().includes("request"));
  check(out() === "request ok {}\n" && JSON.stringify(m.asked[0]) === JSON.stringify({ sysex: true, software: false }), `request result (got ${JSON.stringify(out())} ${JSON.stringify(m.asked)})`);
  check(ev("web::midi::inputs").result === "in1" && ev("web::midi::outputs").result === "out1", "inputs and outputs");
  r = ev("web::midi::info in1");
  check(r.result === "id in1 name Keys manufacturer Fake type input state connected connection closed version 1.0", `info (got ${r.result})`);
  r = ev("web::midi::info nope");
  check(!r.ok && r.result === 'web::midi: no port "nope"', `info of an unknown port (got ${r.result})`);

  r = ev("web::midi::listen in1 {apply {{id m} {puts \"$id $m\"}}}");
  check(r.ok, `listen (got ${r.result})`);
  const input = m.access.inputs.get("in1");
  await until(() => input.connection === "open");
  check(input.connection === "open", "listen opens the port");
  input.play([0x90, 60, 100]);
  input.play([0x80, 60, 0]);
  await until(() => out().includes("128"));
  check(out().endsWith("in1 144 60 100\nin1 128 60 0\n"), `messages (got ${JSON.stringify(out())})`);
  r = ev("web::midi::listen out1 puts");
  check(!r.ok && r.result === 'web::midi: the port "out1" is not an input', `listen to an output (got ${r.result})`);
  ev("web::midi::listen in1 {}");
  input.play([0x90, 61, 1]);
  await tick();
  check(!out().includes("61"), "listen with an empty script ends it");

  const output = m.access.outputs.get("out1");
  r = ev("web::midi::send out1 {0x90 64 127}; web::midi::send out1 {128 64 0} -at 1500.5; web::midi::note out1 67 -velocity 90 -channel 10; web::midi::note out1 67 -off 1");
  check(r.ok, `send (got ${r.result})`);
  check(JSON.stringify(output.sent) === JSON.stringify([[144, 64, 127], [[128, 64, 0], 1500.5], [153, 67, 90], [128, 67, 0]]), `the sent bytes (got ${JSON.stringify(output.sent)})`);
  r = ev("web::midi::send out1 {144 300 1}");
  check(!r.ok && /expected a byte from 0 to 255 but got "300"/.test(r.result), `a bad byte (got ${r.result})`);
  r = ev("web::midi::note out1 128");
  check(!r.ok && /expected a key from 0 to 127/.test(r.result), `a bad key (got ${r.result})`);
  r = ev("web::midi::send in1 {144 1 1}");
  check(!r.ok && /is not an output/.test(r.result), `send to an input (got ${r.result})`);

  ev("web::midi::onchange {apply {{id state} {puts \"change $id $state\"}}}");
  const p2 = new MIDIInput("in2", "Pads");
  m.access.inputs.set("in2", p2);
  m.access.dispatchEvent(new MIDIConnectionEvent("statechange", p2));
  await until(() => out().includes("change"));
  check(out().endsWith("change in2 connected\n"), `onchange (got ${JSON.stringify(out())})`);
  t.close();
}

// A denied permission and a browser without Web MIDI.
{
  const m = midiRoot(true);
  const { t, out } = await session(["web:midi"], m.root);
  t.eval("web::midi::request -command {apply {{s v} {puts \"$s $v\"}}}");
  await until(() => out().includes("error"));
  check(out() === "error web: NotAllowedError: Permission denied.\n", `a denied permission (got ${JSON.stringify(out())})`);
  t.close();
  const s = await session(["web:midi"], { navigator: {} });
  const r = s.t.eval("web::midi::request -command puts");
  check(!r.ok && r.result === "web::midi: this browser has no Web MIDI", `a browser without Web MIDI (got ${r.result})`);
  s.t.close();
}

// The keys demo of the playground.
{
  const m = midiRoot();
  const keys = [];
  for (let n = 60; n <= 72; n++) {
    const k = new FakeEl(`k${n}`);
    k.classList = Object.assign(new Set(), { contains(x) { return this.has(x); }, remove(x) { this.delete(x); } });
    k.className = "key";
    k.getAttribute = (a) => (a === "id" ? k.id : null);
    keys.push(k);
  }
  const els = Object.fromEntries(["go", "out"].map((id) => [id, new FakeEl(id)]));
  const app = new FakeEl("app", [...Object.values(els), ...keys]);
  app.querySelectorAll = (sel) => (sel === ".key" ? keys : []);
  const { t, out } = await session(["dom", "web:midi"], m.root, { domRoot: app });
  const r = t.eval(playground("midi.tcl"));
  check(r.ok, `the MIDI demo script (got ${r.result} ${out()})`);
  check(m.asked.length === 0, "the MIDI demo asks for no access before a click");
  els.go.dispatchEvent(new Event("click"));
  await until(() => els.out.textContent.includes("play to"));
  check(els.out.textContent === "inputs: 1, outputs: 1\nlisten: Keys\nplay to: Synth\n", `the demo output (got ${JSON.stringify(els.out.textContent)} ${out()})`);
  keys[4].dispatchEvent(new Event("pointerdown"));
  keys[4].dispatchEvent(new Event("pointerup"));
  await tick();
  const sent = m.access.outputs.get("out1").sent;
  check(JSON.stringify(sent.slice(0, 2)) === JSON.stringify([[144, 64, 100], [128, 64, 0]]), `a key of the page plays a note (got ${JSON.stringify(sent)})`);
  m.access.inputs.get("in1").play([0x90, 67, 80]);
  await until(() => keys[7].classList.has("on"));
  check(keys[7].classList.has("on"), `a note of the keyboard lights its key (got ${[...keys[7].classList]} ${out()})`);
  m.access.inputs.get("in1").play([0x90, 67, 0]);
  await until(() => !keys[7].classList.has("on"));
  check(!keys[7].classList.has("on"), "a note on with velocity 0 ends the light");
  t.close();
}

// ---- USB ----

class USBConfiguration {
  constructor(v) {
    this.configurationValue = v;
  }
}
class USBInTransferResult {
  constructor(status, data) {
    Object.assign(this, { status, data });
  }
}
class USBOutTransferResult {
  constructor(status, bytesWritten) {
    Object.assign(this, { status, bytesWritten });
  }
}
class USBDevice {
  constructor() {
    Object.assign(this, { vendorId: 0x2e8a, productId: 0x000a, manufacturerName: "Raspberry Pi", productName: "Pico", serialNumber: "E66", deviceClass: 0, opened: false, configuration: null, claimed: [], out: [], inbox: [], waiting: null, controls: [] });
  }
  open() {
    this.opened = true;
    return Promise.resolve();
  }
  close() {
    this.opened = false;
    return Promise.resolve();
  }
  selectConfiguration(v) {
    this.configuration = new USBConfiguration(v);
    return Promise.resolve();
  }
  claimInterface(n) {
    this.claimed.push(n);
    return Promise.resolve();
  }
  transferOut(ep, data) {
    this.out.push([ep, Array.from(data)]);
    // The fake echoes each write in upper case.
    this.send(new TextDecoder().decode(data).toUpperCase());
    return Promise.resolve(new USBOutTransferResult("ok", data.length));
  }
  transferIn(ep, len) {
    return new Promise((res) => {
      const take = () => res(new USBInTransferResult("ok", new DataView(new TextEncoder().encode(this.inbox.shift()).buffer)));
      if (this.inbox.length) take();
      else this.waiting = take;
    });
  }
  send(text) {
    this.inbox.push(text);
    const w = this.waiting;
    this.waiting = null;
    if (w) w();
  }
  controlTransferIn(setup, len) {
    this.controls.push(["in", setup, len]);
    return Promise.resolve(new USBInTransferResult("ok", new DataView(new Uint8Array([1, 2]).buffer)));
  }
  controlTransferOut(setup, data) {
    this.controls.push(["out", setup, Array.from(data ?? [])]);
    return Promise.resolve(new USBOutTransferResult("ok", data ? data.length : 0));
  }
}
class USBConnectionEvent extends Event {
  constructor(type, device) {
    super(type);
    this.device = device;
  }
}
class USB extends EventTarget {
  constructor() {
    super();
    this.device = new USBDevice();
    this.asked = [];
  }
  requestDevice(o) {
    this.asked.push(o);
    return Promise.resolve(this.device);
  }
  getDevices() {
    return Promise.resolve([this.device]);
  }
}

{
  const usb = new USB();
  const { t, out } = await session(["web:usb"], { navigator: { usb } });
  const ev = (s) => t.eval(s);
  let r = ev(`proc got {s dev} {
    set ::dev $dev
    web::usb::open $dev -interface 1 -in 1 -out 2 -command opened
}
proc opened {s chan} {
    if {$s eq "error"} {puts "open error $chan"; return}
    set f [open $chan r+]
    set ::f $f
    fconfigure $f -blocking 0 -buffering line
    fileevent $f readable [list apply {{f} {while {[gets $f line] >= 0} {puts "got $line"}}} $f]
    puts $f hello
}
web::usb::request -vendor 0x2e8a -command got`);
  check(r.ok, `usb request (got ${r.result})`);
  await until(() => out().includes("got HELLO"));
  check(JSON.stringify(usb.asked[0]) === JSON.stringify({ filters: [{ vendorId: 0x2e8a }] }), `usb filters (got ${JSON.stringify(usb.asked)})`);
  check(usb.device.opened && usb.device.configuration?.configurationValue === 1 && usb.device.claimed[0] === 1, "usb open, configure, claim");
  check(JSON.stringify(usb.device.out[0]) === JSON.stringify([2, [...new TextEncoder().encode("hello\n")]]) && out().includes("got HELLO"), `usb channel (got ${JSON.stringify(out())} ${JSON.stringify(usb.device.out)})`);
  r = ev("web::usb::info $::dev");
  check(r.result === "vendor 11914 product 10 manufacturer {Raspberry Pi} name Pico serial E66 class 0 opened 1 configuration 1", `usb info (got ${r.result})`);
  r = ev("fconfigure $::f -mode 9600,n,8,1");
  check(!r.ok && /no -mode/.test(r.result), `usb channel -mode (got ${r.result})`);
  r = ev(`web::usb::control $::dev -direction in -type vendor -recipient interface -request 3 -value 1 -index 0 -length 2 -command {apply {{s v} {binary scan $v cu* n; puts "control $s $n"}}}
web::usb::control $::dev -direction out -type class -recipient interface -request 0x22 -value 3 -index 1`);
  check(r.ok, `usb control (got ${r.result})`);
  await until(() => out().includes("control"));
  check(out().includes("control ok 1 2") && JSON.stringify(usb.device.controls[1]) === JSON.stringify(["out", { requestType: "class", recipient: "interface", request: 34, value: 3, index: 1 }, []]), `usb control transfers (got ${JSON.stringify(usb.device.controls)} ${JSON.stringify(out())})`);
  r = ev("web::usb::transmit $::dev 2 abc -command {apply {{s n} {puts \"sent $s $n\"}}}");
  await until(() => out().includes("sent"));
  check(out().includes("sent ok 3"), `usb transmit (got ${JSON.stringify(out())})`);
  ev("close $::f");
  ev("web::usb::ondisconnect {apply {{d} {puts \"unplugged [dict get [web::usb::info $d] name]\"}}}");
  usb.dispatchEvent(new USBConnectionEvent("disconnect", usb.device));
  await until(() => out().includes("unplugged"));
  check(out().includes("unplugged Pico"), `usb ondisconnect (got ${JSON.stringify(out())})`);
  t.close();
  const s2 = await session(["web:usb"], { navigator: {} });
  r = s2.t.eval("web::usb::devices -command puts");
  check(!r.ok && r.result === "web::usb: this browser has no WebUSB", `a browser without WebUSB (got ${r.result})`);
  s2.t.close();
}

// ---- HID ----

class HIDInputReportEvent extends Event {
  constructor(type, reportId, bytes) {
    super(type);
    Object.assign(this, { reportId, data: new DataView(new Uint8Array(bytes).buffer) });
  }
}
class HIDConnectionEvent extends Event {
  constructor(type, device) {
    super(type);
    this.device = device;
  }
}
class HIDDevice extends EventTarget {
  constructor() {
    super();
    Object.assign(this, { opened: false, vendorId: 0x054c, productId: 0x0ce6, productName: "Fake Controller", collections: [], sent: [] });
  }
  open() {
    this.opened = true;
    return Promise.resolve();
  }
  close() {
    this.opened = false;
    return Promise.resolve();
  }
  sendReport(id, data) {
    this.sent.push(["out", id, Array.from(data)]);
    return Promise.resolve();
  }
  sendFeatureReport(id, data) {
    this.sent.push(["feature", id, Array.from(data)]);
    return Promise.resolve();
  }
  receiveFeatureReport(id) {
    return Promise.resolve(new DataView(new Uint8Array([id, 7]).buffer));
  }
}
class HID extends EventTarget {
  constructor() {
    super();
    this.device = new HIDDevice();
    this.asked = [];
  }
  requestDevice(o) {
    this.asked.push(o);
    return Promise.resolve([this.device]);
  }
  getDevices() {
    return Promise.resolve([this.device]);
  }
}

{
  const hid = new HID();
  const { t, out } = await session(["web:hid"], { navigator: { hid } });
  const ev = (s) => t.eval(s);
  let r = ev(`web::hid::request -vendor 0x054c -page 1 -usage 5 -command {apply {{s devs} {
    set ::dev [lindex $devs 0]
    web::hid::open $::dev -command {apply {{s v} {puts "open $s [web::hid::info $::dev]"}}}
}}}`);
  check(r.ok, `hid request (got ${r.result})`);
  await until(() => out().includes("open"));
  check(JSON.stringify(hid.asked[0]) === JSON.stringify({ filters: [{ vendorId: 0x054c, usagePage: 1, usage: 5 }] }), `hid filters (got ${JSON.stringify(hid.asked)})`);
  check(out() === "open ok vendor 1356 product 3302 name {Fake Controller} opened 1\n", `hid open (got ${JSON.stringify(out())})`);
  ev("web::hid::listen $::dev {apply {{d id bytes} {binary scan $bytes cu* n; puts \"report $id $n\"}}}");
  hid.device.dispatchEvent(new HIDInputReportEvent("inputreport", 1, [128, 127, 0]));
  hid.device.dispatchEvent(new HIDInputReportEvent("inputreport", 2, [9]));
  await until(() => out().includes("report 2"));
  check(out().endsWith("report 1 128 127 0\nreport 2 9\n"), `hid reports (got ${JSON.stringify(out())})`);
  const objs = t._web.objs.size;
  hid.device.dispatchEvent(new HIDInputReportEvent("inputreport", 3, [1]));
  await until(() => out().includes("report 3"));
  check(t._web.objs.size === objs, "hid reports release their event handles");
  r = ev("web::hid::send $::dev 5 [binary format c2 {1 2}]; web::hid::feature $::dev 3 \\x0a; web::hid::feature $::dev 4 -command {apply {{s v} {binary scan $v cu* n; puts \"feature $s $n\"}}}");
  check(r.ok, `hid send and feature (got ${r.result})`);
  await until(() => out().includes("feature"));
  check(JSON.stringify(hid.device.sent) === JSON.stringify([["out", 5, [1, 2]], ["feature", 3, [10]]]) && out().includes("feature ok 4 7"), `hid output and feature reports (got ${JSON.stringify(hid.device.sent)} ${JSON.stringify(out())})`);
  r = ev("web::hid::feature $::dev 4");
  check(!r.ok && /wrong # args/.test(r.result), `hid feature read with no -command (got ${r.result})`);
  ev("web::hid::ondisconnect {apply {{d} {puts \"unplugged [dict get [web::hid::info $d] name]\"}}}");
  hid.dispatchEvent(new HIDConnectionEvent("disconnect", hid.device));
  await until(() => out().includes("unplugged"));
  check(out().includes("unplugged Fake Controller"), `hid ondisconnect (got ${JSON.stringify(out())})`);
  t.close();
  const s2 = await session(["web:hid"], { navigator: {} });
  r = s2.t.eval("web::hid::devices -command puts");
  check(!r.ok && r.result === "web::hid: this browser has no WebHID", `a browser without WebHID (got ${r.result})`);
  s2.t.close();
}

if (failed) {
  console.error(`${failed} failed`);
  process.exit(1);
}
console.log("web group tests pass");
