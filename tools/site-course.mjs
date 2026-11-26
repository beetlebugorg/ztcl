// Tests the shell of a lesson of the Learn course in a headless
// Chromium: the panel is in the window, each Run link runs its command
// and gives its result, the page does not scroll or move, the commands
// of the lesson come back after a reload, and the sheet works on a small
// screen. The server has the site at /ztcl/ (tools/site-helper.mjs has
// the commands):
//
//     node tools/site-course.mjs chromium http://127.0.0.1:8123/ztcl/learn/01-read-a-command/ [shot.png] [chromium flags]
//
// SPDX-License-Identifier: BSD-2-Clause

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [browser, url, shot] = process.argv.slice(2);
const flags = process.argv.slice(5);
const profile = mkdtempSync(join(tmpdir(), "ztcl-shell-"));
const child = spawn(browser, ["--headless=new", "--no-sandbox", "--remote-debugging-pipe", `--user-data-dir=${profile}`, "--no-first-run", ...flags, "about:blank"],
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
await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
await send("Page.enable");
let failed = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : ": " + detail}`);
};



const started = async () => {
  for (let i = 0; i < 300; i++) {
    if (await evalJS(`!!document.querySelector(".zcourse .zshell-screen")`)) return true;
    await pause(100);
  }
  return false;
};
const live = () => evalJS(`document.querySelector(".zcourse [aria-live]").textContent`);
check("the course shell starts", await started());
await evalJS(`sessionStorage.clear()`);
await evalJS(`window.__shift = 0; new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__shift += e.value; }).observe({ type: "layout-shift", buffered: false })`);

// The panel is at the right, all in the window, and the text is at
// its left.
const box = await evalJS(`(() => { const p = document.querySelector(".zcourse").getBoundingClientRect(); const m = document.querySelector("main").getBoundingClientRect(); return { top: p.top, bottom: p.bottom, ih: innerHeight, left: p.left, right: p.right, main: m.right }; })()`);
check("the panel is at the right and in the window", box.top >= 60 && box.bottom <= 900 && box.right <= 1280 && box.main <= box.left, JSON.stringify(box));

// Each Run link runs its command and gives its result. The page does
// not scroll, and nothing moves.
await evalJS(`scrollTo(0, 300)`);
await pause(100);
const runs = await evalJS(`[...document.querySelectorAll(".zrun, .zrun-box")].map((b) => [b.dataset.cmd, b.dataset.want ?? null])`);
let same = true, results = true, ran = 0;
for (let k = 0; k < runs.length; k++) {
  const [cmd, want] = runs[k];
  const y = await evalJS("scrollY");
  await evalJS(`document.querySelectorAll(".zrun, .zrun-box")[${k}].click()`);
  await pause(60);
  const said = await live();
  const y2 = await evalJS("scrollY");
  if (y2 !== y) { same = false; console.log(`  ${cmd}: scrollY ${y} -> ${y2}`); }
  const err = want?.startsWith("error: ");
  const w = err ? want.slice(7) : want;
  if (w && !said.includes(w)) { results = false; console.log(`  ${cmd}: ${JSON.stringify(said)}, want ${JSON.stringify(w)}`); }
  ran++;
}
check(`${ran} Run links keep the scroll position`, same);
check("each Run link gives its result in the shell", results);
const shift = await evalJS("window.__shift");
check("no layout shift", shift < 0.001, String(shift));
check("the focus is in the shell", await evalJS(`document.activeElement?.className === "zshell-input"`));

// A reload runs the commands of the lesson again.
const kept = await evalJS(`JSON.parse(sessionStorage.getItem("ztcl-learn:" + document.querySelector(".zcourse").dataset.lesson) || "[]").length`);
check("the commands of the lesson are in sessionStorage", kept === ran, `${kept} of ${ran}`);
await send("Page.reload");
await pause(500);
await started();
await pause(300);
const screen = await evalJS(`(async () => (await import("./../../assets/shell.js")).pageShell().then((v) => v.shell.text().join("\\n")))()`);
check("a reload runs the commands again", !!screen && screen.includes(`Ran your ${ran} earlier`), screen);
await evalJS(`document.querySelector(".zcourse-again").click()`);
await pause(500);
check("Start again clears the commands", await evalJS(`!sessionStorage.getItem("ztcl-learn:" + document.querySelector(".zcourse").dataset.lesson)`));
if (shot) {
  const { result } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(shot, Buffer.from(result.data, "base64"));
}

// On a small screen the shell is a sheet at the bottom, and the text
// ends above it.
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 800, deviceScaleFactor: 1, mobile: true });
await send("Page.reload");
await pause(500);
await started();
await pause(300);
const sheet = await evalJS(`(() => { const p = document.querySelector(".zcourse").getBoundingClientRect(); const out = [...document.querySelectorAll("body *")].filter((e) => e.getBoundingClientRect().right > document.documentElement.clientWidth + 1).filter((e) => !e.closest(".zcourse-dock, pre")).slice(0, 4).map((e) => e.tagName + "." + e.className + ":" + e.textContent.slice(0, 30)); return { top: p.top, bottom: p.bottom, ih: innerHeight, width: p.width, wide: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, iw: innerWidth, out }; })()`);
check("the shell is a sheet at the bottom", Math.abs(sheet.bottom - sheet.ih) < 2 && sheet.width === 390 && sheet.wide <= 390, JSON.stringify(sheet));
const y = await evalJS("scrollY");
await evalJS(`document.querySelector(".zrun").click()`);
await pause(100);
check("a Run link keeps the scroll position on a small screen", (await evalJS("scrollY")) === y);
await evalJS(`document.querySelector(".zcourse-size").click()`);
await pause(100);
check("Make small makes the sheet small", await evalJS(`document.querySelector(".zcourse").getBoundingClientRect().height < 60`), String(await evalJS(`document.querySelector(".zcourse").getBoundingClientRect().height`)));
if (shot) {
  await evalJS(`document.querySelector(".zcourse-size").click()`);
  await pause(200);
  const { result } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(shot.replace(/\.png$/, "-small.png"), Buffer.from(result.data, "base64"));
}
done(failed ? 1 : 0);
