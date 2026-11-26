// Runs the Tcl test suite on procs compiled to wasm, and compares the
// counts with the interpreter of the same runtime.
//
//   node tools/wasm-aot-suite.mjs [--runner zig-out/bin/ztcl]
//        [--runtime zig-out/lib/ztcl-aot.wasm] [--tests DIR] [-a]
//        [-o FILE] [file.test ...]
//
// For each file: runs tools/tcltest.tcl, then each top-level command of
// the file in its own `ztcl_eval`, then tools/tcltest-end.tcl, in
// ztcl-aot.wasm with the record mode on. It compiles each recorded proc
// and each proc of the file with `ztcl compile --wasm`, runs the file
// again in the new module, and compares the `pass fail skip` line and
// the output. This is the compile-everything mode: each proc of the
// first run has a function in the second run. The wasm build has no
// files, channels, `exec`, or clock, so a test that needs them fails
// or is skipped in both runs.
//
// `--tests` is a folder of test files. The default is the tests folder
// of tools/fetch-tcl.sh core-8-6-16. `-a` runs each .test file of the
// folder. With no file and no -a, it runs the 37 core files of
// tools/suite.sh. `-o` writes one line for each file:
// `file<TAB>pass<TAB>fail<TAB>skip<TAB>same<TAB>found<TAB>missed`.
// The exit status is 1 when a file differs.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const here = path.dirname(new URL(import.meta.url).pathname);
const args = process.argv.slice(2);
let runner = "zig-out/bin/ztcl";
let runtime = "zig-out/lib/ztcl-aot.wasm";
let tests = null;
let all = false;
let log = null;
let files = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--runner") runner = args[++i];
  else if (a === "--runtime") runtime = args[++i];
  else if (a === "--tests") tests = args[++i];
  else if (a === "-a") all = true;
  else if (a === "-o") log = args[++i];
  else files.push(a);
}
if (!tests) tests = execFileSync(path.join(here, "fetch-tcl.sh"), ["core-8-6-16"], { encoding: "utf8" }).trim() + "/tests";
if (all) files = fs.readdirSync(tests).filter((f) => f.endsWith(".test")).sort();
if (files.length === 0) {
  files = "set incr if while for foreach proc uplevel upvar expr list lindex llength lrange linsert lreplace lsearch join split concat append string format switch eval parse lmap apply rename error lset namespace regexp binary info dict scan".split(" ").map((f) => f + ".test");
}

const enc = new TextEncoder();
const dec = new TextDecoder();
const computeLimit = 200_000_000n;
const tcltest = fs.readFileSync(path.join(here, "tcltest.tcl"), "utf8");
const tcltestEnd = fs.readFileSync(path.join(here, "tcltest-end.tcl"), "utf8");

// A Tcl word in double quotes with the text of `s`.
function quoted(s) {
  return '"' + s.replace(/[\\[\]$"]/g, (c) => "\\" + c) + '"';
}

// Runs one test file in a new instance of `module`.
async function runFile(module, text, record) {
  const { exports: x } = await WebAssembly.instantiate(module, {});
  const h = x.ztcl_new();
  if (record) x.ztcl_aot_record(1);
  const out = [];
  const ev = (t) => {
    x.ztcl_set_compute_limit(h, computeLimit);
    const s = enc.encode(t);
    const p = x.ztcl_alloc(s.length);
    new Uint8Array(x.memory.buffer, p, s.length).set(s);
    let rc;
    try {
      rc = x.ztcl_eval(h, p, s.length);
    } catch (e) {
      x.ztcl_free(p, s.length);
      return { rc: 2, result: String(e) };
    }
    x.ztcl_free(p, s.length);
    const result = dec.decode(new Uint8Array(x.memory.buffer, x.ztcl_result_ptr(h), x.ztcl_result_len(h)));
    out.push(dec.decode(new Uint8Array(x.memory.buffer, x.ztcl_output_ptr(h), x.ztcl_output_len(h))));
    x.ztcl_output_clear(h);
    return { rc, result };
  };
  let trapped = false;
  ev(tcltest);
  ev(`set ::tt_wasm_src ${quoted(text)}`);
  const n = ev(`set ::tt_wasm_cmds {}; set ::tt_wasm_c {}
foreach ::tt_wasm_l [split $::tt_wasm_src \\n] {
    append ::tt_wasm_c $::tt_wasm_l \\n
    if {[info complete $::tt_wasm_c]} { lappend ::tt_wasm_cmds $::tt_wasm_c; set ::tt_wasm_c {} }
}
unset ::tt_wasm_src ::tt_wasm_c ::tt_wasm_l
llength $::tt_wasm_cmds`);
  const count = Number(n.result);
  for (let i = 0; i < count && !trapped; i++) {
    const cmd = ev(`lindex $::tt_wasm_cmds ${i}`).result;
    if (cmd.trim() === "") continue;
    const r = ev(cmd);
    // A trap of the engine (the stack of the host) ends the instance.
    if (r.rc === 2) {
      out.push(`trap: ${r.result}\n`);
      trapped = true;
    }
  }
  if (!trapped) ev(tcltestEnd);
  const all = out.join("");
  const m = all.match(/^pass (\d+) fail (\d+) skip (\d+)$/m);
  const res = { output: all, counts: m ? m.slice(1).map(Number) : null, found: x.ztcl_aot_stat(0), missed: x.ztcl_aot_stat(1) };
  if (record) res.record = new Uint8Array(x.memory.buffer, x.ztcl_aot_record_ptr(), x.ztcl_aot_record_len()).slice();
  return res;
}

const base = await WebAssembly.compile(fs.readFileSync(runtime));
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wasm-aot-suite-"));
let bad = 0;
const tot = [0, 0, 0];
let found = 0;
let missed = 0;
if (log) fs.writeFileSync(log, "");
for (const f of files) {
  const file = path.join(tests, f);
  const text = fs.readFileSync(file, "utf8");
  const a = await runFile(base, text, true);
  const rec = path.join(dir, "record.bin");
  const app = path.join(dir, "app.wasm");
  fs.writeFileSync(rec, a.record);
  execFileSync(runner, ["compile", "--wasm", "--runtime", runtime, "--record", rec, "-o", app, file], { stdio: ["ignore", "ignore", "pipe"] });
  const b = await runFile(await WebAssembly.compile(fs.readFileSync(app)), text, false);
  const same = a.output === b.output && JSON.stringify(a.counts) === JSON.stringify(b.counts);
  const c = a.counts ?? [0, 0, 0];
  for (let k = 0; k < 3; k++) tot[k] += c[k];
  found += b.found;
  missed += b.missed;
  if (!same) bad++;
  const line = `${f.padEnd(18)} ${a.counts ? `pass ${c[0]} fail ${c[1]} skip ${c[2]}` : "no result"}  ${same ? "same" : `DIFF compiled ${b.counts ? b.counts.join(" ") : "no result"}`}  ${b.found} found, ${b.missed} with no function`;
  console.log(line);
  if (!same) {
    const la = a.output.split("\n");
    const lb = b.output.split("\n");
    const k = la.findIndex((s, j) => s !== lb[j]);
    console.log(`  first different line ${k}:\n  interpreter: ${la[k]}\n  compiled:    ${lb[k]}`);
  }
  if (log) fs.appendFileSync(log, `${f}\t${c[0]}\t${c[1]}\t${c[2]}\t${same ? 1 : 0}\t${b.found}\t${b.missed}\n`);
}
fs.rmSync(dir, { recursive: true, force: true });
console.log(`total              pass ${tot[0]} fail ${tot[1]} skip ${tot[2]}  ${files.length} files, ${bad} differ, ${found} found, ${missed} with no function`);
process.exit(bad ? 1 : 0);
