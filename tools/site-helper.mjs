// Tests a helper of a docs page (docs/site/helper.js) in a headless
// Chromium: the helper starts in view, shows the command and the result
// that the shell gives, and its button puts the command on the line of
// the shell. It also checks that the shell has the state of the page.
// The helper loads ztk.js from /ztk/play/, so the server has the site at
// /ztcl/ and the files of a ztk web build (zig build wasm) at /ztk/play/:
//
//     mkdir -p srv/ztk && ln -s ../out srv/ztcl && ln -s $ZTK/zig-out/web srv/ztk/play
//     (cd srv && python3 -m http.server 8123) &
//     node tools/site-helper.mjs chromium http://127.0.0.1:8123/ztcl/learn/ [shot.png]
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
setTimeout(() => { console.log("FAIL: timeout"); done(1); }, 120000);

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


// Each helper of the page starts when it comes into view.
const count = await evalJS(`document.querySelectorAll(".zhelper").length`);
for (let k = 0; k < count; k++) {
  await evalJS(`document.querySelectorAll(".zhelper")[${k}].scrollIntoView()`);
  let live = false;
  for (let i = 0; i < 300 && !live; i++) {
    await pause(100);
    live = await evalJS(`document.querySelectorAll(".zhelper")[${k}].classList.contains("zhelper-live") || !!document.querySelectorAll(".zhelper")[${k}].querySelector(".zhelper-poster")?.textContent.includes("did not")`);
  }
  const fig = `document.querySelectorAll(".zhelper")[${k}]`;
  const name = await evalJS(`${fig}.getAttribute("aria-label")`);
  const ok = await evalJS(`${fig}.classList.contains("zhelper-live")`);
  check(`${name} starts in view`, ok, await evalJS(`${fig}.querySelector(".zhelper-app").textContent`));
  if (ok) {
    const res = await evalJS(`${fig}.ztkApp.eval(".foot.res tag ranges error").result`);
    check(`${name} shows a result with no error`, res === "", await evalJS(`${fig}.ztkApp.eval(".foot.res get 1.0 end").result`));
    if (shot) {
      await pause(300);
      const r = await evalJS(`(() => { const b = ${fig}.getBoundingClientRect(); return { x: b.x + scrollX, y: b.y + scrollY, width: b.width, height: Math.min(b.height, 900) }; })()`);
      const { result } = await send("Page.captureScreenshot", { format: "png", clip: { ...r, scale: 1 } });
      writeFileSync(shot.replace(/\.png$/, `-${k + 1}.png`), Buffer.from(result.data, "base64"));
    }
  }
}
const enter = async () => {
  await send("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
  await pause(200);
  return evalJS(`document.querySelector(".zshell [aria-live]").textContent`);
};
const helperApp = (name) => `document.querySelector('.zhelper[aria-label="Helper: ${name}"]')?.ztkApp`;
if (await evalJS(`!!${helperApp("string map")}`)) {
  const app = helperApp("string map");
  const tcl = (s) => evalJS(`${app}.eval(${JSON.stringify(s)}).result`);
  await pause(200);
  check("the helper shows the command", (await tcl("set helper::cmd")) === "string map {cat dog mat rug} {the cat sat on the mat}", await tcl("set helper::cmd"));
  check("the helper shows the result of the shell", (await tcl(".foot.res get 1.0 end-1c")) === "the dog sat on the rug", await tcl(".foot.res get 1.0 end-1c"));
  await tcl("set s {The Cat}; set nocase 1");
  await pause(200);
  check("an edit gives a new command and result", (await tcl(".foot.res get 1.0 end-1c")) === "The dog", await tcl(".foot.res get 1.0 end-1c"));
  await tcl(".foot.put invoke");
  await pause(200);
  check("the button focuses the shell", await evalJS(`document.activeElement?.className === "zshell-input"`));
  await send("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
  await pause(200);
  const said = await evalJS(`document.querySelector(".zshell [aria-live]").textContent`);
  check("the button puts the command on the line of the shell", said === "The dog", JSON.stringify(said));
  await evalJS(`document.querySelector(".zshell-input").focus()`);
  for (const ch of "set words") {
    await send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch });
    await send("Input.dispatchKeyEvent", { type: "keyUp", key: ch });
  }
  await send("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
  await pause(200);
  const state = await evalJS(`document.querySelector(".zshell [aria-live]").textContent`);
  check("the shell has the state of the page", state === "the cat sat on the mat", JSON.stringify(state));
}

if (await evalJS(`!!${helperApp("JSON inspector")}`)) {
  const app = helperApp("JSON inspector");
  const tcl = (s) => evalJS(`${app}.eval(${JSON.stringify(s)}).result`);
  const path = "dict get [lindex [dict get $d users] 0] name";
  check("the inspector shows the parse command", (await tcl("set helper::cmd")) === "set d [ztcl::json parse -null null [readfile users.json]]", await tcl("set helper::cmd"));
  await tcl(".foot.put invoke");
  await pause(200);
  await enter();
  await tcl(`foreach id [array names paths] { if {$paths($id) eq {${path}}} { .f.tree selection set $id } }`);
  await pause(300);
  check("a node gives its path", (await tcl("set helper::cmd")) === path, await tcl("set helper::cmd"));
  check("the path gives its value", (await tcl(".foot.res get 1.0 end-1c")) === "Ada", await tcl(".foot.res get 1.0 end-1c"));
  await tcl(".foot.put invoke");
  await pause(200);
  const said = await enter();
  check("the path runs in the shell", said === "Ada", JSON.stringify(said));
}
// Alt-I opens the inspector on the last result, and a node puts its
// path on the line of the shell.
if (await evalJS(`!!${helperApp("string map")}`)) {
  await evalJS(`document.querySelector(".zshell-input").focus()`);
  for (const ch of "set user") await send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch });
  await enter();
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "i", code: "KeyI", modifiers: 1 });
  await pause(200);
  const rows = await evalJS(`[...document.querySelectorAll("dialog.zshell-inspect .row code")].map((c) => c.textContent).join("|")`);
  check("Alt-I shows the paths of the last result", rows === "set _|dict get $_ name|dict get $_ lang|dict get $_ year", rows);
  await evalJS(`[...document.querySelectorAll("dialog.zshell-inspect .row")].find((r) => r.textContent.startsWith("dict get $_ name")).querySelector("button").click()`);
  await pause(200);
  check("the inspector closes and focuses the shell", await evalJS(`!document.querySelector("dialog") && document.activeElement?.className === "zshell-input"`));
  const said = await enter();
  check("the path of a node runs in the shell", said === "Ada", JSON.stringify(said));
}

if (shot) {
  const { result } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(shot, Buffer.from(result.data, "base64"));
}

// On a small screen each helper is one line until the reader opens it.
if (count) {
  await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 800, deviceScaleFactor: 1, mobile: true });
  await send("Page.reload");
  await pause(1500);
  const fig = `document.querySelector(".zhelper")`;
  check("a helper is one line on a small screen", await evalJS(`${fig}.offsetHeight < 140 && !!${fig}.querySelector(".zhelper-open") && !${fig}.classList.contains("zhelper-live")`),
    String(await evalJS(`${fig}.offsetHeight`)));
  await evalJS(`${fig}.querySelector(".zhelper-open").click()`);
  let live = false;
  for (let i = 0; i < 300 && !live; i++) {
    await pause(100);
    live = await evalJS(`${fig}.classList.contains("zhelper-live")`);
  }
  check("the Open button starts the helper", live);
}
done(failed ? 1 : 0);
