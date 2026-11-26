// Tests the shell of the site (docs/site/shell.js) in a headless
// Chromium. It opens a page, waits for the canvas, sends keys through the
// DevTools protocol, and checks the live region and the meter. It checks
// that the poster and the canvas have the same height, so the page does
// not move when the shell starts.
//
//     python3 -I tools/build-docs.py out && (cd out && python3 -m http.server 8123) &
//     node tools/site-shell.mjs chromium http://127.0.0.1:8123/try/ [shot.png]
//
// The browser reads the messages of the protocol on fd 3 and writes on
// fd 4 (--remote-debugging-pipe). Each message ends with a zero byte.
//
// SPDX-License-Identifier: BSD-2-Clause

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [browser, url, shot] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), "ztcl-shell-"));
const child = spawn(browser, ["--headless=new", "--no-sandbox", "--remote-debugging-pipe", `--user-data-dir=${profile}`, "--no-first-run", "about:blank"],
  { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
let next = 1;
const waiting = new Map();
let buf = Buffer.alloc(0);
child.stdio[4].on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  let end;
  while ((end = buf.indexOf(0)) >= 0) {
    const msg = JSON.parse(buf.subarray(0, end).toString("utf8"));
    buf = buf.subarray(end + 1);
    if (msg.method === "Runtime.exceptionThrown") console.log("exception:", msg.params.exceptionDetails.exception?.description);
    if (msg.id && waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
    }
  }
});
let session;
const send = (method, params = {}) => new Promise((res) => {
  const id = next++;
  waiting.set(id, res);
  child.stdio[3].write(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }) + "\0");
});
const evalJS = async (expr) => {
  const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) console.log("eval:", expr, r.result.exceptionDetails.exception?.description);
  return r.result?.result?.value;
};
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const done = (code) => {
  child.kill();
  rmSync(profile, { recursive: true, force: true });
  process.exit(code);
};
setTimeout(() => { console.log("FAIL: timeout"); done(1); }, 60000);

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Runtime.enable");
await send("Emulation.setFocusEmulationEnabled", { enabled: true });
await send("Emulation.setDeviceMetricsOverride", { width: 1200, height: 900, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
let failed = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : ": " + detail}`);
};

let posterH = 0;
for (let i = 0; i < 100 && !posterH; i++) {
  await pause(50);
  posterH = (await evalJS(`document.querySelector(".zshell-poster")?.offsetHeight ?? 0`)) || 0;
}
let live = false;
for (let i = 0; i < 200 && !live; i++) {
  await pause(100);
  live = await evalJS(`!!document.querySelector(".zshell-screen canvas")`);
}
check("the canvas replaces the poster", live);
if (!live) done(1);
const boxH = await evalJS(`document.querySelector(".zshell-screen").offsetHeight`);
check("the screen has the height of the poster", Math.abs(boxH - posterH) <= 1, `${boxH} vs ${posterH}`);
await evalJS(`document.querySelector(".zshell-input").focus()`);

async function key(k, text, modifiers = 0) {
  const base = { key: k, code: k.length === 1 ? `Key${k.toUpperCase()}` : k, windowsVirtualKeyCode: { Enter: 13, Tab: 9, Escape: 27 }[k] ?? k.toUpperCase().charCodeAt(0) };
  await send("Input.dispatchKeyEvent", { type: "keyDown", modifiers, ...base, ...(text ? { text } : {}) });
  await send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
}
const type = async (s) => { for (const ch of s) await key(ch === " " ? " " : ch, ch); };

await type("pu");
await key("Tab");
await type("hi");
await key("Enter");
await pause(100);
const said = await evalJS(`document.querySelector(".zshell [aria-live]").textContent`);
check("Tab completes puts, and the output goes to the live region", said === "hi", JSON.stringify(said));
const meter = await evalJS(`document.querySelector(".zshell-meter span").textContent`);
check("the meter shows the compute units", /^Last command: \d+ of 10,000,000 compute units$/.test(meter), meter);
await type("set x 1");
await key("x", "", 2);
await key("e", "", 2);
const edited = await evalJS(`document.querySelector("dialog.zshell-editor textarea")?.value`);
check("Ctrl-X Ctrl-E opens the line in an editor", edited === "set x 1", JSON.stringify(edited));
await evalJS(`(() => { const d = document.querySelector("dialog.zshell-editor"); d.querySelector("textarea").value = "set x 2"; d.close("ok"); })()`);
await pause(100);
await key("Enter");
await pause(100);
const back = await evalJS(`document.querySelector(".zshell [aria-live]").textContent`);
check("the edited text goes back to the line", back === "2", JSON.stringify(back));
await type("while 1 {}");
await key("Enter");
await pause(100);
const limit = await evalJS(`document.querySelector(".zshell [aria-live]").textContent`);
check("the compute limit stops a loop", limit.includes("compute limit"), limit);
check("the meter is full after the limit", (await evalJS(`document.querySelector(".zshell-meter progress").value`)) === 10000000);
if (shot) {
  const { result } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(shot, Buffer.from(result.data, "base64"));
}
await key("Escape");
await key("Tab");
check("Escape and Tab move the focus out", await evalJS(`document.activeElement?.className !== "zshell-input"`));
done(failed ? 1 : 0);
