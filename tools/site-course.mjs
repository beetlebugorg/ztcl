// Tests the shell of a lesson of the Learn course in a headless
// Chromium: the shell starts closed and the button Try it does not cover
// the text, Try it opens the panel in the window, each Run link runs its
// command and gives its result, the page does not scroll or move, the
// grip resizes the panel, the commands of the lesson and the state and
// size of the panel come back after a reload, Close closes it, and the
// sheet works on a small screen and opens only on a tap. The server has
// the site at /ztcl/ (tools/site-helper.mjs has the commands):
//
//     node tools/site-course.mjs chromium http://127.0.0.1:8123/ztcl/learn/01-read-a-command/ [shot.png] [chromium flags]
//
// With shot.png the test writes four screenshots next to it:
// shot-closed.png, shot-open.png, shot-small-closed.png, and
// shot-small-open.png.
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
// Windows keeps the files of the profile open until the browser exits,
// so the folder goes after the exit.
const done = (code) => {
  child.once("exit", () => {
    rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    process.exit(code);
  });
  child.kill();
};
setTimeout(() => { console.log("FAIL: timeout"); done(1); }, 120000);

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Runtime.enable");
await send("Emulation.setFocusEmulationEnabled", { enabled: true });
await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
await send("Page.enable");
// Wait for the load of the page, so that a slow network does not race
// the first scroll.
for (let i = 0; i < 300 && (await evalJS("document.readyState")) !== "complete"; i++) await pause(100);
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
const isOpen = () => evalJS(`document.querySelector(".zcourse-dock").classList.contains("open")`);
const reload = async () => {
  await send("Page.reload");
  for (let i = 0; i < 300 && (await evalJS("document.readyState")) !== "complete"; i++) await pause(100);
  await pause(300);
};
// The rectangle of the button Try it, and the right edge of the text of
// the lesson: the right edge of each element in the prose.
const tab = () => evalJS(`(() => { const b = document.querySelector(".zcourse-open").getBoundingClientRect(); const right = Math.max(...[...document.querySelectorAll("main.prose > *")].map((e) => e.getBoundingClientRect().right)); return { left: b.left, top: b.top, right: b.right, bottom: b.bottom, w: b.width, text: right, iw: document.documentElement.clientWidth, ih: innerHeight }; })()`);
const shoot = async (name) => {
  if (!shot) return;
  const { result } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(shot.replace(/\.png$/, `-${name}.png`), Buffer.from(result.data, "base64"));
};
await evalJS(`localStorage.clear(); sessionStorage.clear()`);
await reload();

// The page starts with the shell closed: the button Try it at the bottom
// right, in the gutter at the right of the text.
let b = await tab();
// A helper of the lesson can start the shell, and the shell stays hidden.
check("the shell starts closed", !(await isOpen()) && (await evalJS(`document.querySelector(".zcourse").getBoundingClientRect().width`)) === 0);
check("Try it is at the bottom right and does not cover the text", b.w > 0 && b.bottom <= b.ih && b.ih - b.bottom < 40 && b.iw - b.right < 40 && b.left >= b.text, JSON.stringify(b));
await shoot("closed");

// Try it opens the panel at the bottom right, all in the window.
await evalJS(`document.querySelector(".zcourse-open").click()`);
check("Try it starts the shell", await started());
await pause(300);
const box = await evalJS(`(() => { const p = document.querySelector(".zcourse").getBoundingClientRect(); return { top: p.top, bottom: p.bottom, left: p.left, right: p.right, ih: innerHeight, iw: innerWidth }; })()`);
check("the panel is at the bottom right and in the window", box.top >= 60 && box.bottom <= box.ih && box.right <= box.iw && box.iw - box.right < 40 && box.right - box.left < box.iw / 2, JSON.stringify(box));
check("the focus is in the shell after Try it", await evalJS(`document.activeElement?.className === "zshell-input"`));
await evalJS(`window.__shift = 0; new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__shift += e.value; }).observe({ type: "layout-shift", buffered: false })`);

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
  // The screen wraps long lines, and the shell prints a list one
  // element on each line: compare the text with no white space.
  const flat = (t) => t.replace(/[\s{}]+/g, "");
  if (w && !flat(said).includes(flat(w))) { results = false; console.log(`  ${cmd}: ${JSON.stringify(said)}, want ${JSON.stringify(w)}`); }
  ran++;
}
check(`${ran} Run links keep the scroll position`, same);
check("each Run link gives its result in the shell", results);
const shift = await evalJS("window.__shift");
check("no layout shift", shift < 0.001, String(shift));
if (ran) check("the focus is in the shell", await evalJS(`document.activeElement?.className === "zshell-input"`));
await shoot("open");

// The grip at the top left corner resizes the panel, and the size stays
// for the next page.
const g = await evalJS(`(() => { const r = document.querySelector(".zcourse-grip").getBoundingClientRect(); const p = document.querySelector(".zcourse").getBoundingClientRect(); return { x: r.left + 6, y: r.top + 6, w: p.width, h: p.height }; })()`);
await send("Input.dispatchMouseEvent", { type: "mousePressed", x: g.x, y: g.y, button: "left", clickCount: 1 });
for (let i = 1; i <= 5; i++) await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: g.x - 12 * i, y: g.y - 8 * i, button: "left", buttons: 1 });
await send("Input.dispatchMouseEvent", { type: "mouseReleased", x: g.x - 60, y: g.y - 40, button: "left", clickCount: 1 });
await pause(200);
const g2 = await evalJS(`(() => { const p = document.querySelector(".zcourse").getBoundingClientRect(); return { w: p.width, h: p.height, right: p.right, bottom: p.bottom }; })()`);
check("the grip makes the panel larger", Math.abs(g2.w - g.w - 60) < 3 && Math.abs(g2.h - g.h - 40) < 3, JSON.stringify({ g, g2 }));

// A reload runs the commands of the lesson again, and the shell is open
// again with the same size.
const kept = await evalJS(`JSON.parse(sessionStorage.getItem("ztcl-learn:" + document.querySelector(".zcourse").dataset.lesson) || "[]").length`);
check("the commands of the lesson are in sessionStorage", kept === ran, `${kept} of ${ran}`);
await reload();
check("a reload keeps the shell open", await isOpen());
await started();
await pause(300);
const g3 = await evalJS(`(() => { const p = document.querySelector(".zcourse").getBoundingClientRect(); return { w: p.width, h: p.height }; })()`);
check("a reload keeps the size of the panel", Math.abs(g3.w - g2.w) < 2 && Math.abs(g3.h - g2.h) < 2, JSON.stringify({ g2, g3 }));
const screen = await evalJS(`(async () => (await import(document.querySelector('script[src$="assets/shell.js"]').src)).pageShell().then((v) => v.shell.text().join("\\n")))()`);
if (ran) check("a reload runs the commands again", !!screen && screen.includes(`Ran your ${ran} earlier`), screen);
await evalJS(`document.querySelector(".zcourse-again").click()`);
await pause(500);
check("Start again clears the commands", await evalJS(`!sessionStorage.getItem("ztcl-learn:" + document.querySelector(".zcourse").dataset.lesson)`));

// Close puts the button back, and the next page starts closed.
await evalJS(`document.querySelector(".zcourse-close").click()`);
await pause(100);
check("Close closes the shell", !(await isOpen()) && (await evalJS(`document.activeElement?.className === "zcourse-open"`)));
await reload();
check("a reload keeps the shell closed", !(await isOpen()));

// On a small screen the button is in a strip at the bottom, the text
// ends above the strip, and only a tap opens the sheet: a stored open
// state does not.
await evalJS(`localStorage.setItem("ztcl-course-dock", "open")`);
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 800, deviceScaleFactor: 1, mobile: true });
await reload();
check("the sheet starts closed on a small screen", !(await isOpen()));
b = await tab();
const strip = await evalJS(`(() => { const d = document.querySelector(".zcourse-dock").getBoundingClientRect(); return { top: d.top, bottom: d.bottom, width: d.width, pad: parseFloat(getComputedStyle(document.body).paddingBottom), bg: getComputedStyle(document.querySelector(".zcourse-dock")).backgroundColor }; })()`);
check("Try it is at the bottom right in a strip", Math.abs(b.bottom - b.ih) < 20 && b.iw - b.right < 30 && strip.width === 390 && strip.pad >= strip.bottom - strip.top && strip.bg !== "rgba(0, 0, 0, 0)", JSON.stringify({ b, strip }));
await shoot("small-closed");
const y = await evalJS("scrollY");
if (ran) {
  await evalJS(`document.querySelector(".zrun, .zrun-box").click()`);
  await started();
  await pause(300);
  check("a Run link opens the sheet", await isOpen());
  check("a Run link keeps the scroll position on a small screen", (await evalJS("scrollY")) === y);
} else {
  await evalJS(`document.querySelector(".zcourse-open").click()`);
  await started();
  await pause(300);
}
const sheet = await evalJS(`(() => { const p = document.querySelector(".zcourse").getBoundingClientRect(); const out = [...document.querySelectorAll("body *")].filter((e) => e.getBoundingClientRect().right > document.documentElement.clientWidth + 1).filter((e) => !e.closest(".zcourse-dock, pre")).slice(0, 4).map((e) => e.tagName + "." + e.className + ":" + e.textContent.slice(0, 30)); return { top: p.top, bottom: p.bottom, ih: innerHeight, width: p.width, wide: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, iw: innerWidth, out }; })()`);
check("the shell is a sheet at the bottom", Math.abs(sheet.bottom - sheet.ih) < 2 && sheet.width === 390 && sheet.wide <= 390, JSON.stringify(sheet));
await shoot("small-open");
await evalJS(`document.querySelector(".zcourse-close").click()`);
await pause(100);
check("Close closes the sheet", !(await isOpen()));
done(failed ? 1 : 0);
