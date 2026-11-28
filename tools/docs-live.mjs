// Runs the live examples of pages of the built site in a headless
// Chromium, through the test hook of docs/site/live.js (`?snippettest`):
// each example runs in the page, and each one must end with no error.
// An example of ztcl::typeset or ztcl::pdf must also show the files
// that it writes: each SVG image inline and each PDF in a viewer.
//
//   zig build wasm wasm-threads wasm-shell wasm-host
//   python3 tools/build-docs.py site
//   node tools/docs-live.mjs site /usr/bin/chromium typesetting modules/typeset pdf
//
// With no page, it runs each page of the site that has a live example.
//
// The browser reads the messages of the DevTools protocol on fd 3 and
// writes on fd 4 (--remote-debugging-pipe). Each message ends with a
// zero byte.
//
// SPDX-License-Identifier: BSD-2-Clause

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";

const [siteArg, browserArg, ...pages] = process.argv.slice(2);
const site = path.resolve(siteArg || "site");
const browser = browserArg || process.env.CHROME || "/usr/bin/chromium";
if (!pages.length) {
  for (const f of fs.readdirSync(site, { recursive: true })) {
    if (!f.endsWith("index.html") || f === "index.html") continue;
    if (fs.readFileSync(path.join(site, f), "utf8").includes('class="live-demo"')) pages.push(path.dirname(f));
  }
  pages.sort();
}

const TYPES = { ".html": "text/html", ".mjs": "text/javascript", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".ttf": "font/ttf", ".txt": "text/plain" };
const server = http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (p.endsWith("/")) p += "index.html";
  const f = path.join(site, p);
  if (!f.startsWith(site) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(f)] || "application/octet-stream" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const profile = fs.mkdtempSync(path.join(tmpdir(), "ztcl-docs-"));
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
let failed = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : ": " + detail}`);
};
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
}, 600000);

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Runtime.enable");
await send("Page.enable");

for (const page of pages) {
  pageErrors.length = 0;
  await send("Page.navigate", { url: `${base}/${page}/?snippettest` });
  // A page with no live example does not load live.js.
  let count = null;
  for (let t = 0; t < 10000 && count === null; t += 100) {
    await pause(100);
    count = await evalJS(`document.readyState === "complete" ? document.querySelectorAll("figure.live-demo").length : null`);
  }
  if (!count) {
    check(`${page}: the page has live examples`, false, "none");
    continue;
  }
  let result = null;
  for (let t = 0; t < 120000 && !result; t += 100) {
    await pause(100);
    result = await evalJS(`document.getElementById("result")?.textContent ?? null`);
  }
  if (!result) {
    check(`${page}: the examples end`, false, "no #result");
    continue;
  }
  const r = JSON.parse(result);
  for (const line of r.live) {
    // id:state:ok:output[:files=...]
    const [id, state, ok] = line.split(":");
    check(`${page} ${id}`, state === "1" && ok === "true", line);
  }
  check(`${page}: an edit runs`, r.checks.edit === "42", r.checks.edit);
  check(`${page}: the compute limit stops a loop`, r.checks.limit === "yes", r.checks.limit);
  // The files of the examples that wrote them, as the reader sees them.
  const shown = await evalJS(`JSON.stringify([...document.querySelectorAll("figure.live-demo[data-wasm]")].map((f) => ({
    id: f.id, files: f.dataset.outFiles || "", svg: f.querySelectorAll(".ld-svg svg text").length,
    script: f.querySelectorAll(".ld-svg script").length, pdf: f.querySelectorAll(".ld-file iframe").length,
    links: [...f.querySelectorAll(".ld-file a[download]")].map((a) => a.download).join(" ") })))`);
  for (const f of JSON.parse(shown)) {
    if (!f.files) continue;
    const svgs = f.files.split(" ").filter((n) => n.endsWith(".svg")).length;
    const pdfs = f.files.split(" ").filter((n) => n.endsWith(".pdf")).length;
    if (svgs) check(`${page} ${f.id}: ${svgs} SVG image(s) inline`, f.svg > 0 && f.script === 0, JSON.stringify(f));
    if (pdfs) check(`${page} ${f.id}: ${pdfs} PDF(s) with a viewer and a download`, f.pdf === pdfs && f.links.split(" ").filter(Boolean).length === pdfs, JSON.stringify(f));
  }
  // A PDF of a page is a real PDF: its first bytes, through its blob URL.
  const head = await evalJS(`(async () => { const a = document.querySelector(".ld-file a[download]"); if (!a) return ""; const b = await (await fetch(a.href)).arrayBuffer(); return new TextDecoder().decode(new Uint8Array(b).slice(0, 8)) + " " + b.byteLength; })()`);
  if (head) check(`${page}: the PDF of the blob URL`, head.startsWith("%PDF-"), head);
  check(`${page}: no page errors`, pageErrors.length === 0, pageErrors.join("; "));
}
done(failed ? 1 : 0);
