// The speed gate of compiled point procs (task 06 of
// docs/dev/wasm-compile-tasks/).
//
//   node tools/point-wasm-bench.mjs [--check] [--points N] [--write FILE]
//
// For each fixed proc of tests/point/, the script compiles the module
// with SIMD, makes N points (1,000,000 by default) with each column
// present, and times `run` of the module in Node.js: 3 runs to warm up,
// then the median of 11 runs. The start values of the outputs go back
// into the memory before each run, outside the time. The reference is
// the native `Program.run` (decision 1 of docs/dev/wasm-compile.md):
// zig-out/bin/point-wasm-ref --bench 11 on the same bytes. The script
// prints one row for each proc, and with --write it writes the rows to
// a TSV file. With --check, it exits with 1 when the module is not
// faster than the reference for a proc.
//
// Build first: zig build && zig build point-rt.
//
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
const has = (name) => args.includes(name);
const value = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
};
const n = Number(value("--points", 1000000));
const RUNS = 11;
const WARM = 3;
const FIELDS = ["x", "y", "z", "width", "height", "speed", "flow", "feature", "layer", "path", "dist"];
const OUTS = ["offset", "move_x", "move_y", "width", "flow", "speed", "skip"];
const FEATURE = FIELDS.indexOf("feature");
const WIDTH = FIELDS.indexOf("width");

// A fixed generator, so each run of the script has the same points.
let state = 0x9e3779b97f4a7c15n;
function rnd() {
  state ^= state >> 12n;
  state ^= (state << 25n) & 0xffffffffffffffffn;
  state ^= state >> 27n;
  return Number(((state * 0x2545f4914f6cdd1dn) & 0xffffffffffffffffn) >> 11n) / 2 ** 53;
}

// The points of a toolpath: a circle for each layer, as in a slicer.
function points() {
  const nf = FIELDS.length;
  const no = OUTS.length;
  const buf = new ArrayBuffer(n * 8 * (nf + no) + n);
  for (let k = 0; k < nf; k++) {
    if (k === FEATURE) continue;
    const col = new Float64Array(buf, k * n * 8, n);
    for (let i = 0; i < n; i++) {
      switch (FIELDS[k]) {
        case "x": col[i] = 100 + 40 * Math.cos(i * 0.01); break;
        case "y": col[i] = 100 + 40 * Math.sin(i * 0.01); break;
        case "z": col[i] = 0.2 * Math.floor(i / 5000); break;
        case "width": col[i] = 0.4 + 0.05 * Math.sin(i * 0.3); break;
        case "layer": col[i] = Math.floor(i / 5000); break;
        default: col[i] = (rnd() - 0.5) * 20;
      }
    }
  }
  const feat = new Uint8Array(buf, nf * n * 8, n);
  for (let i = 0; i < n; i++) feat[i] = Math.floor(rnd() * 7);
  const outsAt = nf * n * 8 + n;
  const width = new Float64Array(buf, WIDTH * n * 8, n);
  for (let k = 0; k < no; k++) {
    const col = new Float64Array(n);
    for (let i = 0; i < n; i++) col[i] = OUTS[k] === "width" ? width[i] : 0;
    new Uint8Array(buf, outsAt + k * n * 8, n * 8).set(new Uint8Array(col.buffer));
  }
  return { buf, feat, outsAt };
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}

function benchModule(file, pts) {
  const module = new WebAssembly.Module(fs.readFileSync(file));
  const meta = JSON.parse(new TextDecoder().decode(WebAssembly.Module.customSections(module, "ztcl.point")[0]));
  const x = new WebAssembly.Instance(module, {}).exports;
  if (x.cap.value < n) throw new Error(`${file}: cap ${x.cap.value} is less than ${n} points`);
  const mem = new Uint8Array(x.memory.buffer);
  for (let k = 0; k < FIELDS.length; k++) {
    if (k === FEATURE) {
      if (x.feature) mem.set(pts.feat, x.feature.value);
    } else if (x["in_" + FIELDS[k]]) {
      mem.set(new Uint8Array(pts.buf, k * n * 8, n * 8), x["in_" + FIELDS[k]].value);
    }
  }
  const writes = meta.outputs.map((o) => OUTS.indexOf(o));
  const times = [];
  for (let r = 0; r < WARM + RUNS; r++) {
    for (const k of writes) mem.set(new Uint8Array(pts.buf, pts.outsAt + k * n * 8, n * 8), x["out_" + OUTS[k]].value);
    const t0 = process.hrtime.bigint();
    const steps = x.run(n, 1, 2047, 127, 1n << 62n);
    const ns = Number(process.hrtime.bigint() - t0);
    if (steps < 0n) throw new Error(`${file}: run gave ${steps}`);
    if (r >= WARM) times.push(ns);
  }
  return median(times);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "point-wasm-bench-"));
const inFile = path.join(tmp, "in.bin");
const pts = points();
fs.writeFileSync(inFile, new Uint8Array(pts.buf));
fs.mkdirSync("zig-out/point-wasm", { recursive: true });
// The bytes of the memory: the columns and the scratch of the program.
const maxMem = String(Math.ceil((n * 8 * (FIELDS.length + OUTS.length + 64) + n + (1 << 20)) / 65536) * 65536);

const rows = [["file", "points", "module ns/point", "native ns/point", "ratio"]];
let failed = 0;
for (const name of fs.readdirSync("tests/point").filter((f) => f.endsWith(".tcl")).sort()) {
  const file = path.join("tests/point", name);
  const proc = /^point proc ([A-Za-z0-9_]+) /m.exec(fs.readFileSync(file, "utf8"))[1];
  const out = `zig-out/point-wasm/${path.basename(name, ".tcl")}-bench.wasm`;
  const c = spawnSync("zig-out/bin/ztcl", ["compile", file, "-proc", proc, "-o", out, "-simd", "on", "-max-mem", maxMem]);
  if (c.status !== 0) throw new Error(`ztcl compile ${file}: ${c.stderr}`);
  const mod = benchModule(out, pts) / n;
  const ref = spawnSync("zig-out/bin/point-wasm-ref", [file, proc, inFile, String(n), "1", "2047", "127", "--bench", String(RUNS)], { maxBuffer: 1 << 20 });
  if (ref.status !== 0) throw new Error(`point-wasm-ref ${file}: ${ref.stderr}`);
  const nat = Number(/^ns (\d+)/m.exec(ref.stdout.toString())[1]) / n;
  const ratio = mod / nat;
  if (!(mod < nat)) failed++;
  rows.push([path.basename(name, ".tcl"), String(n), mod.toFixed(2), nat.toFixed(2), ratio.toFixed(2)]);
}
fs.rmSync(tmp, { recursive: true, force: true });
for (const r of rows) console.log(r.join("\t"));
const out = value("--write", null);
if (out) fs.writeFileSync(out, rows.map((r) => r.join("\t")).join("\n") + "\n");
if (has("--check") && failed > 0) {
  console.error(`${failed} procs are not faster in the module than the native Program.run`);
  process.exit(1);
}
