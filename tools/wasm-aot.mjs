// Compares procs compiled to wasm with the interpreter of the same runtime.
//
//   node tools/wasm-aot.mjs [--runner zig-out/bin/ztcl] [--runtime FILE]
//                           [--steps N] [--gc-stress N] [--sweep K]
//                           [--keep DIR] [--quiet] script.tcl ...
//
// For each script: runs it in ztcl-aot.wasm with the record mode on,
// compiles each recorded proc and each proc of the script with
// `ztcl compile --wasm`, runs the script in the new module, and compares
// the result, the output, the error, and the steps used. It prints one
// line for each script, with the functions found and the bodies with no
// function, and exits with 1 when a script differs. `--gc-stress N`
// collects at each Nth safe point in both runs. `--sweep K` also runs
// each script with K step limits below its count, so a script stops at
// each of them in both runs.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const args = process.argv.slice(2);
let runner = "zig-out/bin/ztcl";
let runtime = "zig-out/lib/ztcl-aot.wasm";
let steps = 100_000_000n;
let keep = null;
let quiet = false;
let gcStress = 0;
let sweep = 0;
const files = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--runner") runner = args[++i];
  else if (a === "--runtime") runtime = args[++i];
  else if (a === "--steps") steps = BigInt(args[++i]);
  else if (a === "--keep") keep = args[++i];
  else if (a === "--quiet") quiet = true;
  else if (a === "--gc-stress") gcStress = Number(args[++i]);
  else if (a === "--sweep") sweep = Number(args[++i]);
  else files.push(a);
}

const dec = new TextDecoder();
const enc = new TextEncoder();

// Runs `text` in a new instance of `module`. Returns the result, the
// output, the steps used, the record, and the counts of the lookups.
export async function runIn(module, text, { record = false, stepLimit = steps } = {}) {
  const { exports: x } = await WebAssembly.instantiate(module, {});
  const h = x.ztcl_new();
  x.ztcl_set_step_limit(h, stepLimit);
  if (gcStress) x.ztcl_set_gc_stress(h, gcStress);
  if (record) x.ztcl_aot_record(1);
  const src = enc.encode(text);
  const p = x.ztcl_alloc(src.length);
  new Uint8Array(x.memory.buffer, p, src.length).set(src);
  let rc;
  try {
    rc = x.ztcl_eval(h, p, src.length);
  } catch (e) {
    return { rc: "trap", result: String(e), output: "", steps: 0n, found: 0, missed: 0 };
  }
  const str = (ptr, len) => dec.decode(new Uint8Array(x.memory.buffer, ptr, len));
  const out = {
    rc,
    result: str(x.ztcl_result_ptr(h), x.ztcl_result_len(h)),
    output: str(x.ztcl_output_ptr(h), x.ztcl_output_len(h)),
    steps: stepLimit - x.ztcl_steps_left(h),
    found: x.ztcl_aot_stat(0),
    layoutOk: x.ztcl_aot_stat(4),
    missed: x.ztcl_aot_stat(1),
  };
  if (record) out.record = new Uint8Array(x.memory.buffer, x.ztcl_aot_record_ptr(), x.ztcl_aot_record_len()).slice();
  return out;
}

// Compiles the procs of `file` and of `record` into a module.
export function compileApp(file, record, dir) {
  const rec = path.join(dir, "record.bin");
  const app = path.join(dir, "app.wasm");
  fs.writeFileSync(rec, record);
  const out = execFileSync(runner, ["compile", "--wasm", "--runtime", runtime, "--record", rec, "-o", app, file], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  return { app, log: out };
}

function compare(file, what, a, b) {
  if (a.rc === b.rc && a.result === b.result && a.output === b.output && a.steps === b.steps) return true;
  console.log(`DIFF ${file}${what}`);
  for (const k of ["rc", "result", "output", "steps"]) {
    if (a[k] !== b[k]) console.log(`  ${k}: interpreter ${JSON.stringify(String(a[k])).slice(0, 300)}\n  ${k}: compiled    ${JSON.stringify(String(b[k])).slice(0, 300)}`);
  }
  return false;
}

async function main() {
  const base = await WebAssembly.compile(fs.readFileSync(runtime));
  const dir = keep ?? fs.mkdtempSync(path.join(os.tmpdir(), "wasm-aot-"));
  fs.mkdirSync(dir, { recursive: true });
  let bad = 0;
  let found = 0;
  let missed = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const a = await runIn(base, text, { record: true });
    const { app } = compileApp(file, a.record, dir);
    const b = await runIn(await WebAssembly.compile(fs.readFileSync(app)), text);
    if (!b.layoutOk) {
      console.log("the layout of the runtime differs from ztcl_aot_layout_data: see staticLayout in src/wasm_aot/rt.zig and gen.union32");
      process.exit(1);
    }
    found += b.found;
    missed += b.missed;
    const appMod = await WebAssembly.compile(fs.readFileSync(app));
    let ok = compare(file, "", a, b);
    // The step limit sweep: K limits spread below the count of the run.
    for (let k = 1; ok && k <= sweep; k++) {
      const lim = (a.steps * BigInt(k)) / BigInt(sweep + 1);
      const sa = await runIn(base, text, { stepLimit: lim });
      const sb = await runIn(appMod, text, { stepLimit: lim });
      ok = compare(file, ` at step limit ${lim}`, sa, sb);
    }
    if (!ok) bad++;
    else if (!quiet) console.log(`same ${file}: ${b.found} found, ${b.missed} proc bodies with no function, ${a.steps} steps`);
  }
  if (!keep) fs.rmSync(dir, { recursive: true, force: true });
  console.log(`${files.length} scripts, ${bad} differ, ${found} functions found, ${missed} proc bodies with no function`);
  process.exit(bad ? 1 : 0);
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("wasm-aot.mjs")) await main();
