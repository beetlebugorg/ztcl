// Tests web/ztcl.mjs and the Node.js example on ztcl.wasm.
//   node tools/wasm-web.mjs zig-out/lib/ztcl.wasm
// SPDX-License-Identifier: BSD-2-Clause
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { compile, Interp } from "../web/ztcl.mjs";

const wasm = process.argv[2];
let failed = 0;
const check = (ok, what) => {
  if (!ok) {
    console.error(`FAIL ${what}`);
    failed++;
  }
};

const module = await compile(wasm);
let out = "";
const tcl = await Interp.create(module, { computeLimit: 10_000, memLimit: 8 << 20, onOutput: (t) => (out += t) });
let r = tcl.eval("proc price {q u} {expr {$q * $u}}; puts hi; price 3 4.5");
check(r.ok && r.result === "13.5" && r.output === "hi\n" && out === "hi\n", "eval, result, and output");
r = tcl.eval("set x");
check(!r.ok && r.result.startsWith("can't read"), "error message");
r = tcl.eval("set i 0; while 1 {incr i}");
check(!r.ok && r.result === "compute limit reached", "compute limit");
// The compute limit applies to each eval, and the steps are the same on each run.
tcl.computeLimit = null;
check(tcl.eval("set i").result === "4999", "steps of the stopped loop");
check(tcl.eval("set n 0; while {$n < 100000} {incr n}").ok, "no compute limit");
tcl.close();

const big = await Interp.create(module, { computeLimit: 10_000_000, memLimit: 16 << 20 });
r = big.eval("set s x; catch {while 1 {append s $s}}");
check(!r.ok && r.result === "the script used too much memory", "memory limit");
check(big.memorySize <= 3 * (16 << 20) + (16 << 20), "linear memory near the cap");
// The bomb leaves live data above the limit. The next eval runs, and a
// second bomb stops.
r = big.eval("set x 1; expr {$x+1}");
check(r.ok && r.result === "2", "eval after the memory error");
r = big.eval("set s x; catch {while 1 {append s $s}}");
check(!r.ok && r.result === "the script used too much memory", "memory limit after the memory error");
check(big.memorySize <= 3 * (16 << 20) + (16 << 20), "linear memory near the cap after two errors");
big.close();

const here = path.dirname(fileURLToPath(import.meta.url));
const run = (...args) =>
  spawnSync(process.execPath, [path.join(here, "../examples/web/run.mjs"), "--wasm", wasm, ...args], { encoding: "utf8" });
let p = run(path.join(here, "../examples/web/scripts/fib.tcl"));
check(p.status === 0 && p.stdout === "6765\n", "run.mjs fib");
p = run("--steps", "100000", path.join(here, "../examples/web/scripts/forever.tcl"));
check(p.status === 1 && p.stderr.includes("error: compute limit reached"), "run.mjs compute limit");
p = run("--mem", "16", path.join(here, "../examples/web/scripts/bomb.tcl"));
check(p.status === 1 && p.stderr.includes("error: the script used too much memory"), "run.mjs memory limit");

if (failed) process.exit(1);
console.log("wasm web ok");
