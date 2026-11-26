// Compares the point procs of a wasm library (`pointProc` of
// web/ztcl.mjs) with the native Program.run, on the procs of
// tests/point/.
//
//   zig build wasm-simd point-rt && node tools/wasm-point.mjs zig-out/lib/ztcl-simd.wasm
//
// For each proc and each count of points, the script makes random
// points with special values (NaN, -0, the infinities), runs the proc in
// the library, and runs zig-out/bin/point-wasm-ref on the same bytes.
// Each output must have the same bits, and the compute units must equal
// Program.steps. It also checks that `point` is absent without the
// option `point`, and that the compute limit stops a run.
//
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { compile, Interp } from "../web/ztcl.mjs";

const FIELDS = ["x", "y", "z", "width", "height", "speed", "flow", "feature", "layer", "path", "dist"];
const OUTS = ["offset", "move_x", "move_y", "width", "flow", "speed", "skip"];
const special = [NaN, -0, 0, Infinity, -Infinity, 5e-324, 1, -1, 0.5, 1e300];
let state = 0x2545f4914f6cdd1dn;
function rnd() {
  state ^= state >> 12n;
  state ^= (state << 25n) & 0xffffffffffffffffn;
  state ^= state >> 27n;
  return Number(((state * 0x2545f4914f6cdd1dn) & 0xffffffffffffffffn) >> 11n) / 2 ** 53;
}
const value = (f, i) => {
  if (rnd() < 0.02) return special[Math.floor(rnd() * special.length)];
  if (f === "width") return 0.4 + 0.05 * Math.sin(i * 0.3);
  if (f === "x") return 100 + 40 * Math.cos(i * 0.01);
  if (f === "y") return 100 + 40 * Math.sin(i * 0.01);
  return (rnd() - 0.5) * 20;
};

let failed = 0;
const fail = (what) => {
  console.error(`FAIL ${what}`);
  failed++;
};
const module = await compile(process.argv[2]);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "wasm-point-"));

const plain = await Interp.create(module);
if (plain.eval("info commands point").result !== "") fail("point is present without the option point");
plain.close();

let cases = 0;
for (const name of fs.readdirSync("tests/point").filter((f) => f.endsWith(".tcl")).sort()) {
  const file = path.join("tests/point", name);
  const text = fs.readFileSync(file, "utf8");
  const proc = /^point proc ([A-Za-z0-9_]+) /m.exec(text)[1];
  const tcl = await Interp.create(module, { point: true });
  const r = tcl.eval(text);
  if (!r.ok) {
    fail(`${name}: ${r.result}`);
    continue;
  }
  const p = tcl.pointProc(proc);
  for (const n of [1, 2, 1023, 1025, 3000]) {
    const inputs = {};
    const feature = new Uint8Array(n);
    for (let i = 0; i < n; i++) feature[i] = Math.floor(rnd() * 7);
    const bin = new ArrayBuffer(n * 8 * (FIELDS.length + OUTS.length) + n);
    FIELDS.forEach((f, k) => {
      if (f === "feature") {
        new Uint8Array(bin, FIELDS.length * n * 8, n).set(feature);
        return;
      }
      const col = new Float64Array(n);
      for (let i = 0; i < n; i++) col[i] = value(f, i);
      inputs[f] = col;
      new Uint8Array(bin, k * n * 8, n * 8).set(new Uint8Array(col.buffer));
    });
    const outputs = {};
    OUTS.forEach((o, k) => {
      const col = new Float64Array(n);
      for (let i = 0; i < n; i++) col[i] = o === "width" ? inputs.width[i] : rnd() < 0.5 ? 0 : (rnd() - 0.5) * 0.2;
      outputs[o] = col;
      new Uint8Array(bin, FIELDS.length * n * 8 + n + k * n * 8, n * 8).set(new Uint8Array(col.buffer));
    });
    const inFile = path.join(tmp, "in.bin");
    fs.writeFileSync(inFile, new Uint8Array(bin));
    const ref = spawnSync("zig-out/bin/point-wasm-ref", [file, proc, inFile, String(n), "7", "2047", "127"], { maxBuffer: 1 << 26 });
    if (ref.status !== 0) {
      fail(`${name} n=${n}: point-wasm-ref: ${ref.stderr}`);
      continue;
    }
    const lines = ref.stdout.toString().trim().split("\n");
    const steps = Number(lines.pop().split(" ")[1]);
    lines.pop();
    const units = p.run({ n, seed: 7, inputs, feature, outputs });
    cases++;
    if (units !== steps) fail(`${name} n=${n}: compute units ${units}, Program.steps ${steps}`);
    // The reference writes the columns that the proc writes, in order.
    if (lines.length !== p.outputs.length * n) fail(`${name} n=${n}: ${lines.length / n} reference columns, ${p.outputs.length} outputs`);
    let line = 0;
    let bad = 0;
    for (const o of p.outputs) {
      const u64 = new BigUint64Array(outputs[o].buffer);
      for (let i = 0; i < n; i++) if (u64[i] !== BigInt("0x" + lines[line + i])) bad++;
      line += n;
    }
    if (bad) fail(`${name} n=${n}: ${bad} values differ from Program.run`);
  }
  // The compute limit stops a run before it starts.
  tcl.computeLimit = 1;
  let stopped = false;
  try {
    p.run({ n: 10, outputs: { offset: new Float64Array(10) } });
  } catch (e) {
    stopped = e.message === "compute limit reached";
  }
  if (!stopped) fail(`${name}: the compute limit did not stop the run`);
  tcl.close();
}
fs.rmSync(tmp, { recursive: true, force: true });
if (failed) process.exit(1);
console.log(`wasm point ok: ${cases} cases`);
