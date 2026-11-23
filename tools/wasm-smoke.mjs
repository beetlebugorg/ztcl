// Loads ztcl.wasm in Node.js and runs one script.
//   node tools/wasm-smoke.mjs zig-out/lib/ztcl.wasm
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";

const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {});
const x = instance.exports;
const text = (ptr, len) => new TextDecoder().decode(new Uint8Array(x.memory.buffer, ptr, len));
const h = x.ztcl_new();
const src = new TextEncoder().encode("puts hello; expr {6 * 7}");
const p = x.ztcl_alloc(src.length);
new Uint8Array(x.memory.buffer, p, src.length).set(src);
const rc = x.ztcl_eval(h, p, src.length);
const result = text(x.ztcl_result_ptr(h), x.ztcl_result_len(h));
const output = text(x.ztcl_output_ptr(h), x.ztcl_output_len(h));
if (rc !== 0 || result !== "42" || output !== "hello\n") {
  console.error("wasm check failed", rc, result, output);
  process.exit(1);
}
console.log("wasm ok");
