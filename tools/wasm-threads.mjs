// Tests the capability `thread` of the WebAssembly builds. Run
// `zig build wasm-threads` first.
//
//   node tools/wasm-threads.mjs [node] [browser]
//
// node:    runs the files of tests/thread/ that need no channel with
//          worker_threads, in the shared mode.
// browser: headless Chromium loads a test page from two servers on
//          127.0.0.1. The first server sends the headers COOP and COEP,
//          and the page runs the same files in the shared mode. The
//          second server sends no such header, and the page runs the
//          tests of the async mode (tests/web/threads-async.tcl).
//
// The browser test needs Chromium and playwright-core. Set CHROME to the
// browser and PLAYWRIGHT_CORE to the folder of playwright-core. With no
// PLAYWRIGHT_CORE, the test installs playwright-core in a work folder.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { execFileSync, spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const lib = path.join(root, "zig-out/lib");
const testDir = path.join(root, "tests/thread");
const modes = process.argv.slice(2).length ? process.argv.slice(2) : ["node", "browser"];
let failed = 0;

// The files that need a channel, a file, or a socket. The web builds
// have none of these capabilities.
const skip = new Set(["lib.tcl", "chan.tcl", "collect.tcl"]);
const webDir = path.join(root, "tests/web");

// The limits and capabilities of the line `# thread-tests-flags:`, as
// tools/thread-tests.sh gives them to the runner.
function plan(file) {
  const text = fs.readFileSync(path.join(testDir, file), "utf8");
  const flags = (text.match(/^# thread-tests-flags: (.*)$/m)?.[1] ?? "").split(/\s+/).filter(Boolean);
  const allow = ["thread", "event", "package", "clock"];
  const limits = {};
  const names = { "--threads": "maxThreads", "--thread-steps": "stepLimit", "--thread-mem": "memLimit", "--threads-steps": "totalSteps", "--threads-mem": "totalMem" };
  for (let i = 0; i < flags.length; i += 2) {
    if (flags[i] === "--allow") allow.push(...flags[i + 1].split(","));
    else if (names[flags[i]]) limits[names[flags[i]]] = Number(flags[i + 1]);
    else throw new Error(`${file}: unknown flag ${flags[i]}`);
  }
  return { file, allow, limits, script: fs.readFileSync(path.join(testDir, "lib.tcl"), "utf8") + "\n" + text };
}

// THREAD_FILES limits the run to some files, for example "tsv.tcl sync.tcl".
const only = process.env.THREAD_FILES?.split(/\s+/).filter(Boolean);

export const plans = () =>
  fs
    .readdirSync(testDir)
    .filter((f) => f.endsWith(".tcl") && !skip.has(f) && (!only || only.includes(f)))
    .sort()
    .map(plan);

function report(what, results) {
  for (const r of results) {
    const last = r.output.trimEnd().split("\n").pop();
    const ok = r.ok && / fail 0$/.test(last) && last.startsWith("pass ");
    console.log(`${ok ? "ok" : "FAIL"} ${what} ${r.file}: ${ok ? last : JSON.stringify(r).slice(0, 2000)}`);
    if (!ok) failed++;
  }
}

if (modes.includes("node")) {
  const { runPlan } = await import(path.join(webDir, "threads-run.mjs"));
  const module = path.join(root, "web/ztcl-threads.mjs");
  const wasm = path.join(lib, "ztcl-threads.wasm");
  const results = [];
  for (const p of plans()) results.push(await runPlan(p, { mode: "shared", wasm, module }));
  report("node shared", results);
}

async function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

async function waitFor(url) {
  for (let i = 0; i < 100; i++) {
    try {
      await fetch(url);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error(`the server at ${url} did not start`);
}

// A static server on 127.0.0.1. With `isolate`, it sends the headers
// that make a page cross-origin isolated.
async function serve(dir, isolate, servers) {
  const port = await freePort();
  const headers = isolate
    ? `self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")`
    : "pass";
  const code = `import http.server as h, functools, sys
class H(h.SimpleHTTPRequestHandler):
    extensions_map = {**h.SimpleHTTPRequestHandler.extensions_map, ".mjs": "text/javascript", ".wasm": "application/wasm"}
    def log_message(self, *a):
        pass
    def end_headers(self):
        ${headers}
        super().end_headers()
h.ThreadingHTTPServer(("127.0.0.1", ${port}), functools.partial(H, directory=sys.argv[1])).serve_forever()`;
  servers.push(spawn("python3", ["-I", "-c", code, dir], { stdio: "ignore" }));
  await waitFor(`http://127.0.0.1:${port}/`);
  return `http://127.0.0.1:${port}`;
}

let playwright = null;
function chromium(work) {
  if (!playwright) {
    let from = process.env.PLAYWRIGHT_CORE;
    if (!from) {
      const dir = path.join(work, "playwright");
      fs.mkdirSync(dir);
      fs.writeFileSync(path.join(dir, "package.json"), "{}");
      execFileSync("npm", ["install", "--no-audit", "--no-fund", "--loglevel=error", "playwright-core@^1.50.0"], { cwd: dir, stdio: "inherit" });
      from = path.join(dir, "node_modules/playwright-core");
    }
    playwright = createRequire(import.meta.url)(path.resolve(from));
  }
  return playwright.chromium;
}

async function browserResults(work, url) {
  const chrome = process.env.CHROME || ["/usr/bin/chromium", "/usr/bin/google-chrome", "/usr/bin/chromium-browser"].find((p) => fs.existsSync(p));
  const browser = await chromium(work).launch({ executablePath: chrome });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(url);
    await page.waitForFunction(() => document.getElementById("result")?.textContent, null, { timeout: 600_000 });
    const got = JSON.parse(await page.locator("#result").textContent());
    if (errors.length) got.push({ file: "page errors", ok: false, output: errors.join("\n") });
    return got;
  } finally {
    await browser.close();
  }
}

if (modes.includes("browser")) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "ztcl-threads-"));
  const servers = [];
  try {
    const site = path.join(work, "site");
    fs.mkdirSync(site);
    for (const f of ["ztcl.mjs", "ztcl-threads.mjs", "ztcl-thread-worker.mjs"]) fs.copyFileSync(path.join(root, "web", f), path.join(site, f));
    for (const f of ["ztcl-threads.wasm", "ztcl-async.wasm"]) fs.copyFileSync(path.join(lib, f), path.join(site, f));
    fs.copyFileSync(path.join(webDir, "threads-run.mjs"), path.join(site, "threads-run.mjs"));
    const asyncPlan = { file: "threads-async.tcl", allow: ["thread"], limits: { stepLimit: 1_000_000, memLimit: 32 << 20 }, script: fs.readFileSync(path.join(testDir, "lib.tcl"), "utf8") + "\n" + fs.readFileSync(path.join(webDir, "threads-async.tcl"), "utf8") };
    fs.writeFileSync(path.join(site, "plans.json"), JSON.stringify({ shared: plans(), async: [asyncPlan] }));
    fs.writeFileSync(
      path.join(site, "index.html"),
      `<!doctype html><meta charset="utf-8"><title>ztcl threads</title><pre id="result"></pre>
<script type="module">
import { runPlan } from "./threads-run.mjs";
const plans = await (await fetch("plans.json")).json();
const mode = crossOriginIsolated ? "shared" : "async";
const out = [];
for (const p of plans[mode]) out.push({ ...(await runPlan(p, { mode })), isolated: crossOriginIsolated });
document.getElementById("result").textContent = JSON.stringify(out);
</script>
`,
    );
    const isolatedBase = await serve(site, true, servers);
    const plainBase = await serve(site, false, servers);
    report("chromium isolated", await browserResults(work, `${isolatedBase}/index.html`));
    report("chromium not isolated", await browserResults(work, `${plainBase}/index.html`));
  } finally {
    for (const p of servers) p.kill();
    fs.rmSync(work, { recursive: true, force: true });
  }
}

console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
