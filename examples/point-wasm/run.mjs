// A Node.js host for a point proc that `ztcl compile` made.
//
//   zig-out/bin/ztcl compile tests/point/fuzzy.tcl -proc fuzzy -o fuzzy.wasm
//   node examples/point-wasm/run.mjs fuzzy.wasm
//
// The host reads the custom section `ztcl.point`, writes a column for
// each parameter into the memory of the module, writes the feature
// number of each point, calls `run` with a compute limit, and prints the
// first outputs. The ABI is in docs/webassembly.md.
//
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";

const file = process.argv[2];
if (!file) {
  console.error("usage: node examples/point-wasm/run.mjs MODULE.wasm");
  process.exit(2);
}
const module = new WebAssembly.Module(fs.readFileSync(file));
const meta = JSON.parse(new TextDecoder().decode(WebAssembly.Module.customSections(module, "ztcl.point")[0]));
if (meta.abi !== 1) throw new Error(`ABI ${meta.abi}: this host reads ABI 1`);
// The module has no imports, so the import object is empty.
const x = new WebAssembly.Instance(module, {}).exports;

// The bits of in_mask and out_mask follow these orders.
const FIELDS = ["x", "y", "z", "width", "height", "speed", "flow", "feature", "layer", "path", "dist"];
const OUTS = ["offset", "move_x", "move_y", "width", "flow", "speed", "skip"];

// The points: one circle of a perimeter at z = 0.4.
const n = Math.min(2000, x.cap.value);
const column = (name) => new Float64Array(x.memory.buffer, x["in_" + name].value, n);
let inMask = 0;
for (const p of meta.params) {
  inMask |= 1 << FIELDS.indexOf(p);
  if (p === "feature") {
    // A feature is the index of its name in meta.features.
    const wall = meta.features.indexOf("outer_wall");
    new Uint8Array(x.memory.buffer, x.feature.value, n).fill(wall);
    continue;
  }
  const col = column(p);
  for (let i = 0; i < n; i++) {
    const t = (2 * Math.PI * i) / n;
    col[i] = p === "x" ? 50 + 20 * Math.cos(t) : p === "y" ? 50 + 20 * Math.sin(t) : p === "z" ? 0.4 : 0;
  }
}

// Each output starts at 0. The module writes only the outputs of the proc.
let outMask = 0;
const outs = {};
for (const o of meta.outputs) {
  outMask |= 1 << OUTS.indexOf(o);
  outs[o] = new Float64Array(x.memory.buffer, x["out_" + o].value, n);
  outs[o].fill(0);
}

// A compute limit of 1,000,000 compute units for this call.
const used = x.run(n, 1, inMask, outMask, 1000000n);
if (used === -1n) throw new Error("the compute limit stopped the proc");
if (used === -2n) throw new Error(`more points than cap (${x.cap.value})`);
console.log(`${meta.proc}: ${n} points, ${used} compute units`);
for (const o of meta.outputs) console.log(`${o}: ${Array.from(outs[o].slice(0, 4), (v) => v.toFixed(6)).join(" ")} ...`);
