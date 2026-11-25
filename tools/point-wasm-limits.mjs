// Checks the step limit and the memory limit of a compiled point proc.
//
//   node tools/point-wasm-limits.mjs [MODULE.wasm]
//
// The default module is zig-out/fuzzy.wasm (`ztcl compile
// tests/point/fuzzy.tcl -proc fuzzy -o zig-out/fuzzy.wasm`). The checks:
// a run with the exact steps of Program.steps(n) works and returns them;
// a run with one step less stops with -1, also one step short of the
// first block or of the setup; n = cap + 1 gives -2; and a grow of the
// memory from the host fails, because the maximum equals the minimum.
//
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";

const file = process.argv[2] || "zig-out/fuzzy.wasm";
const module = new WebAssembly.Module(fs.readFileSync(file));
const meta = JSON.parse(new TextDecoder().decode(WebAssembly.Module.customSections(module, "ztcl.point")[0]));
const x = new WebAssembly.Instance(module, {}).exports;
const setup = BigInt(meta.setup_steps);
const ops = BigInt(meta.block_steps);
const steps = (n) => setup + BigInt(Math.ceil(n / meta.block)) * ops;
const all = (1 << 11) - 1;
let failed = 0;
function check(name, got, want) {
  const ok = got === want;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}: ${got}${ok ? "" : ` (expected ${want})`}`);
  if (!ok) failed++;
}

const n = 3000;
check("n = 3000 with Program.steps(n)", x.run(n, 1, all, 127, steps(n)), steps(n));
check("n = 3000 with one step less", x.run(n, 1, all, 127, steps(n) - 1n), -1n);
check("one step short of the first block", x.run(n, 1, all, 127, setup + ops - 1n), -1n);
check("one step short of the setup", x.run(n, 1, all, 127, setup - 1n), -1n);
check("n = 0 with the setup steps", x.run(0, 1, all, 127, setup), setup);
check(`n = cap = ${x.cap.value}`, x.run(x.cap.value, 1, all, 127, steps(x.cap.value)), steps(x.cap.value));
check("n = cap + 1", x.run(x.cap.value + 1, 1, all, 127, 1n << 62n), -2n);
check("n = 2^31 (a negative i32)", x.run(-(2 ** 31), 1, all, 127, 1n << 62n), -2n);
const desc = WebAssembly.Module.exports(module).find((e) => e.name === "memory");
check("memory size in bytes", x.memory.buffer.byteLength, meta.memory);
let grew;
try {
  x.memory.grow(1);
  grew = "grew";
} catch (e) {
  grew = e.constructor.name;
}
check("a grow from the host past the maximum", grew, "RangeError");
if (!desc) failed++;
process.exit(failed ? 1 : 0);
