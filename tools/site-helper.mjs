// Tests a helper of a docs page (docs/site/helper.js) in a headless
// Chromium: the helper starts in view, shows the command and the result
// that the shell gives, and its button puts the command on the line of
// the shell. It also checks that the shell has the state of the page.
// The helper loads ztk.js from /ztk/play/, so the server has the site at
// /ztcl/ and the files of a ztk web build (zig build wasm) at /ztk/play/:
//
//     mkdir -p srv/ztk && ln -s ../out srv/ztcl && ln -s $ZTK/zig-out/web srv/ztk/play
//     (cd srv && python3 -m http.server 8123) &
//     node tools/site-helper.mjs chromium http://127.0.0.1:8123/ztcl/learn/05-strings-and-patterns/ [shot.png]
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
    if (await evalJS(`${fig}.ztkApp.eval("winfo exists .foot.res").result === "1"`)) {
      const res = await evalJS(`${fig}.ztkApp.eval(".foot.res tag ranges error").result`);
      check(`${name} shows a result with no error`, res === "", await evalJS(`${fig}.ztkApp.eval(".foot.res get 1.0 end").result`));
    }
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
  return evalJS(`document.querySelector(".zpage-shell [aria-live]").textContent`);
};
const helperApp = (name) => `document.querySelector('.zhelper[aria-label="Helper: ${name}"]')?.ztkApp`;
if (await evalJS(`!!${helperApp("Build a regexp")}`)) {
  const app = helperApp("Build a regexp");
  const tcl = (s) => evalJS(`${app}.eval(${JSON.stringify(s)}).result`);
  await pause(200);
  check("the helper shows the command", (await tcl("set helper::cmd")) === "regexp -all -inline {#(\\w+)} {buy milk #home #shop}", await tcl("set helper::cmd"));
  check("the helper shows the result of the shell", (await tcl(".foot.res get 1.0 end-1c")) === "{#home} home #shop shop", await tcl(".foot.res get 1.0 end-1c"));
  await tcl("set str {#a}; set all 0");
  await pause(200);
  check("an edit gives a new command and result", (await tcl(".foot.res get 1.0 end-1c")) === "{#a} a", await tcl(".foot.res get 1.0 end-1c"));
  // The page keeps its scroll position: the shell docks in the window.
  const before = await evalJS("scrollY");
  await tcl(".foot.put invoke");
  await pause(400);
  const after = await evalJS("scrollY");
  check("the button keeps the scroll position of the page", after === before, `${before} -> ${after}`);
  check("the shell is in view after the button", await evalJS(`(() => { const r = document.querySelector(".zshell-screen").getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; })()`));
  check("the button focuses the shell", await evalJS(`document.activeElement?.className === "zshell-input"`));
  const said = await enter();
  check("the button puts the command on the line of the shell", said === "{#a} a", JSON.stringify(said));
  if (await evalJS(`!!document.querySelector(".zshell-dock")`)) {
    await evalJS(`document.querySelector(".zshell-dock").click()`);
    await pause(200);
    check("Put back returns the shell to the page", await evalJS(`!document.querySelector(".zshell-docked") && scrollY === ${after}`), await evalJS("scrollY"));
  }
  await evalJS(`document.querySelector(".zshell-input").focus({ preventScroll: true })`);
  for (const ch of "set text") {
    await send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch });
    await send("Input.dispatchKeyEvent", { type: "keyUp", key: ch });
  }
  const state = await enter();
  check("the shell has the state of the page", state === "buy milk #home #shop", JSON.stringify(state));
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
if (await evalJS(`!!${helperApp("Build a regexp")}`)) {
  await evalJS(`document.querySelector(".zshell-input").focus({ preventScroll: true })`);
  for (const ch of "dict create name Ada lang Tcl year 1843") await send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch });
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

// On a small screen each helper is its title line and its caption until
// the reader opens it.
if (count) {
  await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 800, deviceScaleFactor: 1, mobile: true });
  await send("Page.reload");
  await pause(1500);
  const fig = `document.querySelector(".zhelper")`;
  check("a closed helper is short on a small screen", await evalJS(`${fig}.offsetHeight < 180 && !!${fig}.querySelector(".zhelper-open") && !${fig}.classList.contains("zhelper-live")`),
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
