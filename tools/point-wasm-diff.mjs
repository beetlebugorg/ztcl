// Compares a compiled point proc with Program.run and point.runSlow.
//
//   node tools/point-wasm-diff.mjs FILE.tcl PROC MODULE.wasm [--seed S]
//
// For each case (a count of points and a set of present columns), the
// script makes random points with special values (NaN, -0, the
// infinities, the subnormals), runs `run` of the module in Node.js, and
// runs zig-out/bin/point-wasm-ref on the same bytes. The reference
// checks that Program.run and point.runSlow give equal bits and writes
// the outputs of Program.run. The script compares the bits of each
// output and the step count.
//
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const [file, proc, modPath, ...rest] = process.argv.slice(2);
const opt = (name, def) => {
  const i = rest.indexOf(name);
  return i >= 0 ? Number(rest[i + 1]) : def;
};
let state = BigInt(opt("--seed", 7)) | 1n;
const FIELDS = ["x", "y", "z", "width", "height", "speed", "flow", "feature", "layer", "path", "dist"];
const OUTS = ["offset", "move_x", "move_y", "width", "flow", "speed", "skip"];
const FEATURE = FIELDS.indexOf("feature");
const WIDTH = FIELDS.indexOf("width");

function next() {
  state ^= state >> 12n;
  state ^= (state << 25n) & 0xffffffffffffffffn;
  state ^= state >> 27n;
  return (state * 0x2545f4914f6cdd1dn) & 0xffffffffffffffffn;
}
const rnd = () => Number(next() >> 11n) / 2 ** 53;
const special = [NaN, -0, 0, Infinity, -Infinity, 5e-324, -5e-324, 1, -1, 0.5, 1e300, -1e300];

const bytes = fs.readFileSync(modPath);
const module = new WebAssembly.Module(bytes);
if (WebAssembly.Module.imports(module).length !== 0) throw new Error("the module has imports");
const meta = JSON.parse(new TextDecoder().decode(WebAssembly.Module.customSections(module, "ztcl.point")[0]));
const instance = new WebAssembly.Instance(module, {});
const x = instance.exports;
const cap = x.cap.value;
const writes = meta.outputs.map((o) => OUTS.indexOf(o));

// A value of a field: often near a path, sometimes special.
function fieldValue(k, i) {
  const r = rnd();
  if (r < 0.02) return special[Math.floor(rnd() * special.length)];
  switch (FIELDS[k]) {
    case "x":
      return 100 + 40 * Math.cos(i * 0.01) + rnd() * 1e-3;
    case "y":
      return 100 + 40 * Math.sin(i * 0.01);
    case "z":
      return 0.2 * Math.floor(i / 500);
    case "width":
      return 0.4 + 0.05 * Math.sin(i * 0.3);
    default:
      return (rnd() - 0.5) * 20;
  }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "point-wasm-"));
let failures = 0;
let cases = 0;
let skippedSlow = 0;

function runCase(n, inMask, outMask, seed) {
  const nf = FIELDS.length;
  const no = OUTS.length;
  const buf = new ArrayBuffer(n * 8 * (nf + no) + n + 8);
  const fields = [];
  for (let k = 0; k < nf; k++) {
    const col = new Float64Array(buf, k * n * 8, n);
    for (let i = 0; i < n; i++) col[i] = fieldValue(k, i);
    fields.push(col);
  }
  const feat = new Uint8Array(buf, nf * n * 8, n);
  for (let i = 0; i < n; i++) feat[i] = Math.floor(rnd() * 7);
  const outsAt = nf * n * 8 + n;
  const outBytes = new Uint8Array(buf, outsAt, no * n * 8);
  const starts = [];
  for (let k = 0; k < no; k++) {
    // Each output column starts with its own values: the width input
    // for `width`, small values or 0 for the others.
    const col = new Float64Array(n);
    for (let i = 0; i < n; i++) col[i] = OUTS[k] === "width" ? fields[WIDTH][i] : rnd() < 0.5 ? 0 : (rnd() - 0.5) * 0.2;
    starts.push(col);
    outBytes.set(new Uint8Array(col.buffer), k * n * 8);
  }
  const inFile = path.join(tmp, "in.bin");
  fs.writeFileSync(inFile, new Uint8Array(buf, 0, n * 8 * (nf + no) + n));
  const ref = spawnSync("zig-out/bin/point-wasm-ref", [file, proc, inFile, String(n), String(seed), String(inMask), String(outMask)], { maxBuffer: 1 << 28 });
  if (ref.status !== 0) {
    console.error(`case n=${n} in_mask=${inMask} out_mask=${outMask}: point-wasm-ref failed (${ref.status}): ${ref.stderr}`);
    fs.writeFileSync(path.join("zig-out", "point-wasm-fail.bin"), new Uint8Array(buf, 0, n * 8 * (nf + no) + n));
    failures++;
    return;
  }
  const lines = ref.stdout.toString().trim().split("\n");
  const wantSteps = BigInt(lines.pop().split(" ")[1]);
  skippedSlow += Number(lines.pop().split(" ")[1]);

  // The module: copy the bytes of each present column.
  const mem = new Uint8Array(x.memory.buffer);
  for (let k = 0; k < nf; k++) {
    if (k === FEATURE) {
      if (x.feature) mem.set(feat, x.feature.value);
    } else if (x["in_" + FIELDS[k]]) {
      mem.set(new Uint8Array(buf, k * n * 8, n * 8), x["in_" + FIELDS[k]].value);
    }
  }
  for (const k of writes) mem.set(new Uint8Array(starts[k].buffer), x["out_" + OUTS[k]].value);
  const steps = x.run(n, seed | 0, inMask, outMask, 1n << 62n);
  cases++;
  if (steps !== wantSteps) {
    console.error(`case n=${n} in_mask=${inMask} out_mask=${outMask}: steps ${steps}, Program.steps ${wantSteps}`);
    failures++;
  }
  const u64 = new BigUint64Array(x.memory.buffer);
  let line = 0;
  let shown = 0;
  for (let k = 0; k < no; k++) {
    if (!(outMask & (1 << k)) || !writes.includes(k)) continue;
    const base = x["out_" + OUTS[k]].value / 8;
    for (let i = 0; i < n; i++) {
      const want = BigInt("0x" + lines[line++]);
      const got = u64[base + i];
      if (got !== want) {
        if (shown++ < 5) {
          const p = FIELDS.map((f, j) => `${f}=${j === FEATURE ? feat[i] : fields[j][i]}`).join(" ");
          console.error(`case n=${n} in_mask=${inMask} out_mask=${outMask}: ${OUTS[k]}[${i}] module 0x${got.toString(16)} native 0x${want.toString(16)} (${p})`);
        }
        failures++;
      }
    }
  }
}

const all = (1 << FIELDS.length) - 1;
const allOut = (1 << OUTS.length) - 1;
const counts = [0, 1, 2, 3, 1023, 1024, 1025, 2049, Math.min(5001, cap)];
for (const n of counts) runCase(n, all, allOut, 12345);
for (let t = 0; t < 12; t++) {
  const n = 1 + Math.floor(rnd() * 3000);
  runCase(n, Number(next() & BigInt(all)), Number(next() & BigInt(allOut)), Number(next() & 0xffffffffn));
}
fs.rmSync(tmp, { recursive: true });
console.log(`${modPath}: ${proc}: ${cases} cases, ${failures} differences, ${skippedSlow} points with a Tcl error on the slow path`);
process.exit(failures ? 1 : 0);
