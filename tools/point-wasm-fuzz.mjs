// Runs the modules of one batch of tools/point-wasm-fuzz.zig.
//
//   node tools/point-wasm-fuzz.mjs BATCH.bin
//
// BATCH.bin has a u32 count, then for each case: a u32 length and the
// module, the u32 values n, seed, in_mask, and out_mask, the 11 input
// columns of n f64, n feature bytes, and the 7 output columns of n f64
// with the start values. For each case the script writes to stdout the
// i64 result of `run` and the bits of each output column that the proc
// writes and that out_mask has, in column order.
//
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";

const FIELDS = ["x", "y", "z", "width", "height", "speed", "flow", "feature", "layer", "path", "dist"];
const OUTS = ["offset", "move_x", "move_y", "width", "flow", "speed", "skip"];
const buf = fs.readFileSync(process.argv[2]);
const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
let pos = 0;
const u32 = () => {
  pos += 4;
  return dv.getUint32(pos - 4, true);
};
const out = [];
const count = u32();
for (let c = 0; c < count; c++) {
  const len = u32();
  const module = new WebAssembly.Module(buf.subarray(pos, pos + len));
  pos += len;
  const [n, seed, inMask, outMask] = [u32(), u32(), u32(), u32()];
  const x = new WebAssembly.Instance(module, {}).exports;
  const mem = new Uint8Array(x.memory.buffer);
  for (let k = 0; k < FIELDS.length; k++) {
    if (k !== FIELDS.indexOf("feature") && x["in_" + FIELDS[k]]) mem.set(buf.subarray(pos, pos + n * 8), x["in_" + FIELDS[k]].value);
    pos += n * 8;
  }
  if (x.feature) mem.set(buf.subarray(pos, pos + n), x.feature.value);
  pos += n;
  for (let k = 0; k < OUTS.length; k++) {
    if (x["out_" + OUTS[k]]) mem.set(buf.subarray(pos, pos + n * 8), x["out_" + OUTS[k]].value);
    pos += n * 8;
  }
  const steps = x.run(n, seed | 0, inMask, outMask, 1n << 62n);
  const s = Buffer.alloc(8);
  s.writeBigInt64LE(steps);
  out.push(s);
  for (let k = 0; k < OUTS.length; k++) {
    if (!(outMask & (1 << k)) || !x["out_" + OUTS[k]]) continue;
    const at = x["out_" + OUTS[k]].value;
    out.push(Buffer.from(mem.subarray(at, at + n * 8)));
  }
}
process.stdout.write(Buffer.concat(out));
