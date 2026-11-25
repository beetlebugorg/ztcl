// Times scripts on procs compiled to wasm, on the interpreter of the
// same runtime, and on a native tclsh.
//
//   node tools/wasm-aot-bench.mjs [--runner zig-out/bin/ztcl]
//        [--runtime zig-out/lib/ztcl-aot.wasm] [--tclsh tclsh] [--runs N]
//        [--kostya] [script.tcl ...]
//
// For each script: runs it once in the runtime with the record mode,
// compiles its procs with `ztcl compile --wasm`, then gives the best of
// N runs (5 by default) of the `eval` in each module, and the best of N
// runs of the whole tclsh process. The output of each mode must be
// equal, or the line says so.
//
// `--kostya` adds `brainfuck/bf.tcl bench.b` and `base64/test.tcl` of
// tools/fetch-kostya.sh. The wasm build has no files, sockets, or
// clock, so a prelude gives `open`, `read`, `close`, `flush`, `pid`, `notify`,
// and `clock milliseconds` with fixed results, and the time fields of
// base64 are not compared. tclsh runs the files as they are.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const here = path.dirname(new URL(import.meta.url).pathname);
const args = process.argv.slice(2);
let runner = "zig-out/bin/ztcl";
let runtime = "zig-out/lib/ztcl-aot.wasm";
let tclsh = "tclsh";
let runs = 5;
let kostya = false;
const files = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--runner") runner = args[++i];
  else if (a === "--runtime") runtime = args[++i];
  else if (a === "--tclsh") tclsh = args[++i];
  else if (a === "--runs") runs = Number(args[++i]);
  else if (a === "--kostya") kostya = true;
  else files.push(a);
}

const quoted = (s) => '"' + s.replace(/[\\[\]$"]/g, (c) => "\\" + c) + '"';
const jobs = files.map((f) => ({ name: f, text: fs.readFileSync(f, "utf8"), native: [f], cwd: undefined, mask: null }));
if (kostya) {
  const k = execFileSync(path.join(here, "fetch-kostya.sh"), { encoding: "utf8" }).trim();
  const shim = (files) => `proc notify {msg} {}
proc pid {} { return 0 }
proc clock {args} { return 0 }
proc open {name args} { return $name }
proc close {f} {}
proc flush {args} {}
proc read {f} { return [set ::tt_file($f)] }
${Object.entries(files).map(([n, t]) => `set ::tt_file(${n}) ${quoted(t)}`).join("\n")}
`;
  const bfDir = path.join(k, "brainfuck");
  const bench = fs.readFileSync(path.join(bfDir, "bench.b"), "utf8");
  jobs.push({ name: "kostya bf.tcl bench.b", text: shim({ "bench.b": bench }) + "set argv bench.b\n" + fs.readFileSync(path.join(bfDir, "bf.tcl"), "utf8"), native: ["bf.tcl", "bench.b"], cwd: bfDir, mask: null });
  const b64Dir = path.join(k, "base64");
  jobs.push({ name: "kostya base64/test.tcl", text: shim({}) + fs.readFileSync(path.join(b64Dir, "test.tcl"), "utf8"), native: ["test.tcl"], cwd: b64Dir, mask: /[0-9.]+(?=\s*$)/gm });
}

const enc = new TextEncoder();
const dec = new TextDecoder();
async function evalIn(module, text, record) {
  const { exports: x } = await WebAssembly.instantiate(module, {});
  const h = x.ztcl_new();
  if (record) x.ztcl_aot_record(1);
  const s = enc.encode(text);
  const p = x.ztcl_alloc(s.length);
  new Uint8Array(x.memory.buffer, p, s.length).set(s);
  const t = performance.now();
  const rc = x.ztcl_eval(h, p, s.length);
  const ms = performance.now() - t;
  const out = dec.decode(new Uint8Array(x.memory.buffer, x.ztcl_output_ptr(h), x.ztcl_output_len(h)));
  const result = dec.decode(new Uint8Array(x.memory.buffer, x.ztcl_result_ptr(h), x.ztcl_result_len(h)));
  const rec = record ? new Uint8Array(x.memory.buffer, x.ztcl_aot_record_ptr(), x.ztcl_aot_record_len()).slice() : null;
  return { ms, out: rc === 0 ? out : `${out}error: ${result}`, rec };
}

async function best(module, text) {
  let r = null;
  for (let k = 0; k < runs; k++) {
    const x = await evalIn(module, text, false);
    if (!r || x.ms < r.ms) r = x;
  }
  return r;
}

const base = await WebAssembly.compile(fs.readFileSync(runtime));
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wasm-aot-bench-"));
console.log("| Script | wasm interpreter | compiled | ratio | tclsh |");
console.log("|---|---|---|---|---|");
for (const j of jobs) {
  const first = await evalIn(base, j.text, true);
  const src = path.join(dir, "script.tcl");
  const rec = path.join(dir, "record.bin");
  const app = path.join(dir, "app.wasm");
  fs.writeFileSync(src, j.text);
  fs.writeFileSync(rec, first.rec);
  execFileSync(runner, ["compile", "--wasm", "--runtime", runtime, "--record", rec, "-o", app, src], { stdio: "ignore" });
  const a = await best(base, j.text);
  const b = await best(await WebAssembly.compile(fs.readFileSync(app)), j.text);
  let tms = Infinity;
  let tout = "";
  for (let k = 0; k < runs; k++) {
    const t = performance.now();
    tout = execFileSync(tclsh, j.native, { cwd: j.cwd, encoding: "utf8", maxBuffer: 1 << 28 });
    tms = Math.min(tms, performance.now() - t);
  }
  const norm = (s) => (j.mask ? s.replace(j.mask, "T") : s).trimEnd();
  const note = norm(a.out) !== norm(b.out) ? " (compiled output differs)" : norm(a.out) !== norm(tout) ? " (tclsh output differs)" : "";
  const f = (ms) => (ms >= 1000 ? `${(ms / 1000).toFixed(2)} s` : `${ms.toFixed(1)} ms`);
  console.log(`| ${j.name}${note} | ${f(a.ms)} | ${f(b.ms)} | ${(b.ms / a.ms).toFixed(2)} | ${f(tms)} |`);
}
fs.rmSync(dir, { recursive: true, force: true });
