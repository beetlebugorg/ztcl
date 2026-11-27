// Runs the demo pages of the Web APIs (docs/site/playground/*.html) in a
// headless Chromium. A small server gives the files at the paths of the
// built site, and a fake device API goes into each page before its
// scripts, so the Tcl script of the demo runs end to end in the browser.
//
//   zig build wasm-host
//   node tools/web-demos.mjs /usr/bin/chromium
//
// The browser reads the messages of the DevTools protocol on fd 3 and
// writes on fd 4 (--remote-debugging-pipe). Each message ends with a
// zero byte.
//
// SPDX-License-Identifier: BSD-2-Clause
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const browser = process.argv[2] || process.env.CHROME || "/usr/bin/chromium";

// The file of a path of the site, as tools/build-docs.py puts it.
function fileOf(url) {
  const p = decodeURIComponent(new URL(url, "http://x").pathname);
  if (p.startsWith("/assets/")) return path.join(root, "docs/site", p.slice(8));
  if (!p.startsWith("/playground/")) return null;
  const name = p.slice(12);
  if (name.includes("/") || name.includes("..")) return null;
  if (name.endsWith(".wasm")) return path.join(root, "zig-out/lib", name);
  if (fs.existsSync(path.join(root, "web", name))) return path.join(root, "web", name);
  return path.join(root, "docs/site/playground", name);
}
const TYPES = { ".html": "text/html", ".mjs": "text/javascript", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".tcl": "text/plain", ".svg": "image/svg+xml" };
const server = http.createServer((req, res) => {
  const f = fileOf(req.url);
  if (!f || !fs.existsSync(f)) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(f)] || "application/octet-stream" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const profile = fs.mkdtempSync(path.join(tmpdir(), "ztcl-demos-"));
const child = spawn(browser, ["--headless=new", "--no-sandbox", "--remote-debugging-pipe", `--user-data-dir=${profile}`, "--no-first-run", "about:blank"], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
let next = 1;
const waiting = new Map();
const pageErrors = [];
let buf = Buffer.alloc(0);
child.stdio[4].on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  let end;
  while ((end = buf.indexOf(0)) >= 0) {
    const msg = JSON.parse(buf.subarray(0, end).toString("utf8"));
    buf = buf.subarray(end + 1);
    if (msg.method === "Runtime.exceptionThrown") pageErrors.push(msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text);
    if (msg.id && waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
    }
  }
});
let session;
const send = (method, params = {}) =>
  new Promise((res) => {
    const id = next++;
    waiting.set(id, res);
    child.stdio[3].write(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }) + "\0");
  });
const evalJS = async (expr) => {
  const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) return `exception: ${r.result.exceptionDetails.exception?.description}`;
  return r.result?.result?.value;
};
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const waitJS = async (expr, ms = 15000) => {
  for (let t = 0; t < ms; t += 50) {
    if (await evalJS(expr)) return true;
    await pause(50);
  }
  return false;
};
let failed = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : ": " + detail}`);
};
// Ends the browser, then removes its profile. Chrome can still write to
// the profile for a moment after the signal, so the removal waits for
// the exit and tries again.
const done = (code) => {
  server.close();
  const finish = () => {
    try {
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
    } catch {}
    process.exit(code);
  };
  child.once("exit", finish);
  setTimeout(finish, 5000);
  child.kill();
};
setTimeout(() => {
  console.log("FAIL: timeout");
  done(1);
}, 120000);

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Runtime.enable");
await send("Page.enable");

// Opens a demo page with `fake`, a script that runs before the scripts of
// the page, and waits for the text of #support.
async function open(name, fake) {
  const { result } = await send("Page.addScriptToEvaluateOnNewDocument", { source: fake });
  pageErrors.length = 0;
  await send("Page.navigate", { url: `${base}/playground/${name}` });
  await waitJS(`(document.getElementById("support")?.textContent ?? "") !== ""`);
  await send("Page.removeScriptToEvaluateOnNewDocument", { identifier: result.identifier });
  return evalJS(`document.getElementById("support").textContent`);
}
const text = (id) => evalJS(`document.getElementById(${JSON.stringify(id)}).textContent`);

// ---- Bluetooth: a fake heart-rate monitor ----

const fakeBluetooth = `(() => {
  class BluetoothRemoteGATTCharacteristic extends EventTarget {
    constructor(service) { super(); this.service = service; this.uuid = "00002a37-0000-1000-8000-00805f9b34fb"; this.value = null; }
    startNotifications() {
      let n = 0;
      const beat = () => { this.value = new DataView(new Uint8Array([0, 60 + n++]).buffer); this.dispatchEvent(new Event("characteristicvaluechanged")); };
      this.timer = setInterval(beat, 20);
      return Promise.resolve(this);
    }
    stopNotifications() { clearInterval(this.timer); return Promise.resolve(this); }
  }
  class BluetoothRemoteGATTService extends EventTarget {
    constructor(device) { super(); this.device = device; this.uuid = "0000180d-0000-1000-8000-00805f9b34fb"; this.isPrimary = true; this.ch = new BluetoothRemoteGATTCharacteristic(this); }
    getCharacteristic() { return Promise.resolve(this.ch); }
  }
  class BluetoothRemoteGATTServer {
    constructor(device) { this.device = device; this.connected = false; this.svc = new BluetoothRemoteGATTService(device); }
    connect() { this.connected = true; return Promise.resolve(this); }
    disconnect() { this.connected = false; clearInterval(this.svc.ch.timer); this.device.dispatchEvent(new Event("gattserverdisconnected")); }
    getPrimaryService() { return Promise.resolve(this.svc); }
  }
  class BluetoothDevice extends EventTarget {
    constructor() { super(); this.id = "fake"; this.name = "Fake HRM"; this.gatt = new BluetoothRemoteGATTServer(this); }
  }
  class Bluetooth extends EventTarget {
    requestDevice(o) { window.__asked = (window.__asked || 0) + 1; window.__options = JSON.stringify(o); return Promise.resolve(new BluetoothDevice()); }
  }
  Object.defineProperty(Navigator.prototype, "bluetooth", { configurable: true, get: () => (window.__bt ??= new Bluetooth()) });
})();`;

{
  const say = await open("bluetooth.html", fakeBluetooth);
  check("bluetooth: the page is ready", /^Ready\./.test(say), say);
  check("bluetooth: no request before a click", !(await evalJS("window.__asked")));
  await evalJS(`document.getElementById("go").click()`);
  const beat = await waitJS(`Number(document.getElementById("bpm").textContent) >= 63`);
  check("bluetooth: the rate of the notifications", beat, await text("bpm"));
  check("bluetooth: the filter of the request", (await evalJS("window.__options")) === '{"filters":[{"services":["heart_rate"]}]}', await evalJS("window.__options"));
  await evalJS(`document.getElementById("stop").click()`);
  await waitJS(`document.getElementById("out").textContent.includes("disconnected")`);
  const out = await text("out");
  check("bluetooth: the output", out === "device: Fake HRM\nnotifications on\ndisconnected\n", JSON.stringify(out));
  check("bluetooth: no page errors", pageErrors.length === 0, pageErrors.join("; "));
}

// A browser with no Web Bluetooth.
{
  const say = await open("bluetooth.html", `Object.defineProperty(Navigator.prototype, "bluetooth", { configurable: true, get: () => undefined });`);
  check("bluetooth: the text for a browser without the API", /has no Web Bluetooth/.test(say), say);
  check("bluetooth: the buttons are off without the API", await evalJS(`document.getElementById("go").disabled`));
}

// ---- Gamepad: a fake pad with the left stick to the right ----

const fakePad = `(() => {
  const pad = () => ({ id: "Fake Pad (STANDARD GAMEPAD)", index: 0, connected: true, timestamp: performance.now(), mapping: "standard",
    axes: [1, 0, 0, 0], buttons: Array.from({ length: 17 }, (_, i) => ({ pressed: i === 0, touched: i === 0, value: i === 0 ? 1 : 0 })), touches: [] });
  Navigator.prototype.getGamepads = function () { window.__reads = (window.__reads || 0) + 1; return [pad(), null, null, null]; };
})();`;

{
  const say = await open("gamepad.html", fakePad);
  check("gamepad: the page is ready", /^Ready\./.test(say), say);
  check("gamepad: no poll before a click", !(await evalJS("window.__reads")));
  await evalJS(`document.getElementById("go").click()`);
  const moved = await waitJS(`parseFloat(document.getElementById("ball").style.left) >= 80`);
  check("gamepad: the stick moves the ball", moved, await evalJS(`document.getElementById("ball").style.left`));
  check("gamepad: the buttons", (await text("buttons")) === "0", await text("buttons"));
  await evalJS(`document.getElementById("stop").click()`);
  await pause(100);
  const reads = await evalJS("window.__reads");
  await pause(200);
  check("gamepad: stop ends the poll", (await evalJS("window.__reads")) === reads);
  check("gamepad: no page errors", pageErrors.length === 0, pageErrors.join("; "));
}

done(failed ? 1 : 0);
