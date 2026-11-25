// Compares the runtime of compiled point procs with the native code.
//
//   node tools/point-rt-diff.mjs [--count N] [--seed S]
//
// Run `zig build point-rt` first. The script makes N records of random
// f64 bits, random values in small ranges, and pairs of special values
// (NaN, -0, the infinities, the subnormals). It calls each export of
// zig-out/lib/point_rt.wasm and zig-out/lib/point_rt_scalar.wasm on
// each record, runs zig-out/bin/point-rt-ref on the same records, and
// compares the bits. The order of the outputs is the order of
// tools/point-rt-ref.zig.
//
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 ? Number(args[i + 1]) : def;
};
const count = opt("--count", 100000);
let state = BigInt(opt("--seed", 1)) | 1n;

const fn1 = ["acos", "asin", "atan", "cos", "cosh", "exp", "log", "log10", "sin", "sinh", "tan", "tanh", "round"];
const fn2 = ["atan2", "fmod", "hypot", "pow"];
const names = [...fn1, ...fn2, "clamp", "noise3", ...["offset", "move_x", "move_y", "width", "flow", "speed", "skip"].map((o) => "bound." + o)];
const outputs = names.length;
const fmt = (v) => (Object.is(v, -0) ? "-0" : String(v));

const special = [
  NaN, -0, 0, Infinity, -Infinity, 1, -1, 0.5, -0.5, 2, 5e-324, -5e-324, 2.2250738585072014e-308,
  2.225073858507201e-308, 1.7976931348623157e308, -1.7976931348623157e308, Math.PI, 1e-300, 1e300, 2e9, -2e9,
];
const bits = new BigUint64Array(1);
const asF = new Float64Array(bits.buffer);
function next() {
  // xorshift64*
  state ^= state >> 12n;
  state ^= (state << 25n) & 0xffffffffffffffffn;
  state ^= state >> 27n;
  return (state * 0x2545f4914f6cdd1dn) & 0xffffffffffffffffn;
}
function value() {
  const r = next();
  switch (Number(r & 3n)) {
    case 0:
      bits[0] = next();
      return asF[0];
    case 1:
      return special[Number((r >> 8n) % BigInt(special.length))];
    case 2:
      return (Number(r >> 11n) / 2 ** 53 - 0.5) * 20;
    default:
      return (Number(r >> 11n) / 2 ** 53 - 0.5) * 2000;
  }
}

const records = new Float64Array(count * 4);
const recBits = new BigUint64Array(records.buffer);
for (let i = 0; i < count; i++) {
  records[i * 4] = value();
  records[i * 4 + 1] = value();
  records[i * 4 + 2] = value();
  recBits[i * 4 + 3] = next() & 0xffffffffn;
}

const ref = spawnSync("zig-out/bin/point-rt-ref", [], {
  input: Buffer.from(records.buffer),
  maxBuffer: count * outputs * 8 + 1024,
});
if (ref.status !== 0) {
  console.error("point-rt-ref failed", ref.stderr.toString());
  process.exit(1);
}
const want = new BigUint64Array(ref.stdout.buffer.slice(ref.stdout.byteOffset, ref.stdout.byteOffset + ref.stdout.length));
if (want.length !== count * outputs) {
  console.error("point-rt-ref wrote", want.length, "values, expected", count * outputs);
  process.exit(1);
}

let failed = false;
for (const file of ["zig-out/lib/point_rt.wasm", "zig-out/lib/point_rt_scalar.wasm"]) {
  const { instance } = await WebAssembly.instantiate(fs.readFileSync(file), {});
  const x = instance.exports;
  const imports = WebAssembly.Module.imports(new WebAssembly.Module(fs.readFileSync(file)));
  if (imports.length !== 0) {
    console.error(file, "has imports");
    process.exit(1);
  }
  // The columns of `bound` at the end of the memory, past the stack.
  const end = x.memory.buffer.byteLength;
  const base = end - 4096;
  const f64 = new Float64Array(x.memory.buffer);
  const u32 = new Uint32Array(x.memory.buffer);
  const u64 = new BigUint64Array(x.memory.buffer);
  const outsAt = base;
  const widthAt = base + 64;
  const limitsAt = base + 128;
  const colsAt = base + 256;
  for (let k = 0; k < 7; k++) u32[outsAt / 4 + k] = colsAt + k * 8;
  [1.0, 1.0, 0.25, 2.0, 0.4].forEach((v, k) => (f64[limitsAt / 8 + k] = v));
  // A probe of one f64 result: stored through memory to keep the bits.
  const probe = base + 512;
  const got = new BigUint64Array(outputs);
  let diffs = 0;
  let nanPayloads = 0;
  const byName = {};
  for (let i = 0; i < count; i++) {
    const [a, b, c] = [records[i * 4], records[i * 4 + 1], records[i * 4 + 2]];
    const seed = Number(recBits[i * 4 + 3]);
    let k = 0;
    const put = (v) => {
      f64[probe / 8] = v;
      got[k++] = u64[probe / 8];
    };
    for (const f of fn1) put(x["rt_" + f](a));
    for (const f of fn2) put(x["rt_" + f](a, b));
    put(x.rt_clamp(a, b, c));
    put(x.rt_noise3(seed, a, b, c));
    // The columns get the bits of the records. A JavaScript number can
    // set the quiet bit of a signaling NaN.
    const [ab, bb, cb] = [recBits[i * 4], recBits[i * 4 + 1], recBits[i * 4 + 2]];
    [ab, bb, cb, bb, ab, bb, cb].forEach((v, j) => (u64[colsAt / 8 + j] = v));
    u64[widthAt / 8] = cb;
    x.rt_bound(1, widthAt, outsAt, limitsAt);
    for (let j = 0; j < 7; j++) got[k++] = u64[colsAt / 8 + j];
    for (let j = 0; j < outputs; j++) {
      const w = want[i * outputs + j];
      if (got[j] === w) continue;
      // JavaScript numbers may change the payload of a NaN, so a NaN
      // result of a function call compares as NaN. The columns of
      // `bound` stay in memory and compare as bits.
      bits[0] = w;
      const wNaN = Number.isNaN(asF[0]);
      bits[0] = got[j];
      if (j < outputs - 7 && wNaN && Number.isNaN(asF[0])) {
        nanPayloads++;
        byName[names[j] + " (NaN payload)"] = (byName[names[j] + " (NaN payload)"] || 0) + 1;
        continue;
      }
      byName[names[j]] = (byName[names[j]] || 0) + 1;
      diffs++;
      if (byName[names[j]] <= 3) {
        console.error(`${file}: ${names[j]}(${fmt(a)}, ${fmt(b)}, ${fmt(c)}, seed ${seed}): wasm 0x${got[j].toString(16)} native 0x${w.toString(16)}`);
      }
    }
  }
  console.log(`${file}: ${count} records, ${count * outputs} values, ${diffs} differences, ${nanPayloads} NaN results with another payload`);
  if (diffs > 0 || nanPayloads > 0) console.log(JSON.stringify(byName));
  if (diffs > 0) failed = true;
}
process.exit(failed ? 1 : 0);
