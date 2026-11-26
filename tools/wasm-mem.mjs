// Runs the scripts of tests/mem on the WebAssembly build.
//
//   node tools/wasm-mem.mjs zig-out/lib/ztcl.wasm [--browser path] [--stress] [script ...]
//
// Each script runs with N passes and with 10 N passes, each in a new
// instance. The linear memory never shrinks, so its final size is the
// peak. A script is flat when the size for 10 N is at most 10 % above the
// size for N. With --stress, each script runs with a small N, with a
// collection at each safe point, and its output must equal the output
// with no stress.
//
// With --browser, a local page runs the same code in that browser. The
// page and the results use the loopback address only.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

// This function also runs in the browser, so it uses no Node.js API.
async function runAll(bytes, scripts, stress) {
  const module = await WebAssembly.compile(bytes);
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  async function once(text, n, gcStress) {
    const { exports: x } = await WebAssembly.instantiate(module, {});
    const h = x.ztcl_new();
    x.ztcl_set_compute_limit(h, 100000000000n);
    x.ztcl_set_mem_limit(h, 1 << 30);
    if (gcStress) x.ztcl_set_gc_stress(h, gcStress);
    const src = enc.encode(`set argv ${n}\n${text}`);
    const p = x.ztcl_alloc(src.length);
    new Uint8Array(x.memory.buffer, p, src.length).set(src);
    const rc = x.ztcl_eval(h, p, src.length);
    const read = (a, l) => dec.decode(new Uint8Array(x.memory.buffer, a, l));
    const result = read(x.ztcl_result_ptr(h), x.ztcl_result_len(h));
    const output = read(x.ztcl_output_ptr(h), x.ztcl_output_len(h));
    return { rc, result, output, bytes: x.memory.buffer.byteLength };
  }
  const rows = [];
  for (const s of scripts) {
    if (stress) {
      const n = Math.min(40, Math.ceil(s.n / 10000));
      const a = await once(s.text, n, 0);
      const b = await once(s.text, n, 1);
      const same = a.rc === b.rc && a.result === b.result && a.output === b.output;
      rows.push({ name: s.name, n, ok: same && a.rc === 0, note: same ? `rc ${a.rc}` : `differs: ${b.result.slice(0, 60)}` });
      continue;
    }
    const a = await once(s.text, s.n, 0);
    const b = await once(s.text, s.n * 10, 0);
    const flat = b.bytes * 10 <= a.bytes * 11;
    const good = a.rc === 0 && b.rc === 0;
    rows.push({ name: s.name, n: s.n, a: a.bytes, b: b.bytes, ok: flat && good, note: good ? (flat ? "flat" : "GROWS") : `error: ${(a.rc ? a.result : b.result).slice(0, 60)}` });
  }
  return rows;
}

function printRows(rows) {
  for (const r of rows) {
    if (r.a === undefined) console.log(`${r.name.padEnd(9)} ${String(r.n).padStart(8)}  ${r.ok ? "same" : "FAIL"}  ${r.note}`);
    else console.log(`${r.name.padEnd(9)} ${String(r.n).padStart(8)} ${String(r.a).padStart(12)} ${String(r.b).padStart(12)}  ${r.note}`);
  }
  return rows.every((r) => r.ok);
}

// Serves the page, waits for its result, and stops the browser.
async function inBrowser(browser, bytes, scripts, stress) {
  const page = `<!doctype html><meta charset=utf-8><title>wasm-mem</title><script type=module>
const runAll = ${runAll.toString()};
try {
  const bytes = await (await fetch("/wasm")).arrayBuffer();
  const scripts = await (await fetch("/scripts")).json();
  const rows = await runAll(bytes, scripts, ${stress});
  await fetch("/result", { method: "POST", body: JSON.stringify({ rows, agent: navigator.userAgent }) });
} catch (e) {
  await fetch("/result", { method: "POST", body: JSON.stringify({ error: String(e) }) });
}
</script>`;
  let finish;
  const done = new Promise((r) => (finish = r));
  const server = http.createServer((req, res) => {
    if (req.url === "/") return res.writeHead(200, { "content-type": "text/html" }).end(page);
    if (req.url === "/wasm") return res.writeHead(200, { "content-type": "application/wasm" }).end(bytes);
    if (req.url === "/scripts") return res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(scripts));
    if (req.url === "/result") {
      let body = "";
      req.on("data", (d) => (body += d));
      req.on("end", () => {
        res.writeHead(200).end();
        finish(JSON.parse(body));
      });
      return;
    }
    res.writeHead(404).end();
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "ztcl-browser-"));
  const firefox = /firefox/.test(path.basename(browser));
  const args = firefox
    ? ["--headless", "--no-remote", "--profile", profile, url]
    : ["--headless=new", "--no-first-run", "--disable-gpu", `--user-data-dir=${profile}`, url];
  const proc = spawn(browser, args, { stdio: "ignore" });
  const timer = setTimeout(() => finish({ error: "the browser run timed out" }), 900000);
  const out = await done;
  clearTimeout(timer);
  const gone = new Promise((r) => proc.once("exit", r));
  proc.kill("SIGTERM");
  await Promise.race([gone, new Promise((r) => setTimeout(r, 5000))]);
  if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGKILL");
  server.close();
  fs.rmSync(profile, { recursive: true, force: true });
  return out;
}

const argv = process.argv.slice(2);
const wasm = argv.shift();
let browser = null;
let stress = false;
const names = [];
while (argv.length) {
  const a = argv.shift();
  if (a === "--browser") browser = argv.shift();
  else if (a === "--stress") stress = true;
  else names.push(a);
}
// WebAssembly has no coroutines, so the `coro` script does not apply.
if (!names.length) names.push("lset", "pass", "lassign", "switch", "method", "b64enc", "b64dec", "append", "list", "dict", "proc");
const here = path.dirname(fileURLToPath(import.meta.url));
const scripts = names.map((name) => ({
  name,
  n: name.startsWith("b64") ? 300 : name === "append" ? 1500000 : 300000,
  text: fs.readFileSync(path.join(here, "..", "tests", "mem", `${name}.tcl`), "utf8"),
}));
const bytes = fs.readFileSync(wasm);
let rows;
if (browser) {
  const out = await inBrowser(browser, bytes, scripts, stress);
  if (out.error) {
    console.error(out.error);
    process.exit(1);
  }
  console.log(out.agent);
  rows = out.rows;
} else {
  console.log(`node ${process.version}`);
  rows = await runAll(bytes, scripts, stress);
}
process.exit(printRows(rows) ? 0 : 1);
