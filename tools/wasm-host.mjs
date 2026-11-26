// Tests ztcl-host.wasm, the form with the imports of `ztcl_host`, against
// ztcl.wasm (docs/dev/wasm-host-tasks/README.md).
//
//   node tools/wasm-host.mjs zig-out/lib/ztcl.wasm zig-out/lib/ztcl-host.wasm
//
// SPDX-License-Identifier: BSD-2-Clause
import { compile, Interp } from "../web/ztcl.mjs";

const [strictPath, hostPath] = process.argv.slice(2);
let failed = 0;
const check = (ok, what) => {
  if (!ok) {
    console.error(`FAIL ${what}`);
    failed++;
  }
};
const strict = await compile(strictPath);
const host = await compile(hostPath);
check(WebAssembly.Module.imports(strict).length === 0, "ztcl.wasm has no imports");
check(WebAssembly.Module.imports(host).every((i) => i.module === "ztcl_host"), "ztcl-host.wasm imports only ztcl_host");

// Task 02: each puts reaches onOutput at the time of the call, in order.
const seen = [];
const tcl = await Interp.create(host, { onOutput: (t) => seen.push(t) });
const r = tcl.eval("puts a; puts b; puts c; set x done");
check(r.ok && r.result === "done", "eval with live output");
check(seen.length === 3 && seen.join("") === "a\nb\nc\n", `three live calls in order (got ${JSON.stringify(seen)})`);
check(r.output === "a\nb\nc\n", "the output of the eval has the live text");
tcl.close();

// The compute limit stops a loop that writes at the same point in each form.
const stop = async (mod) => {
  const t = await Interp.create(mod, { computeLimit: 5000, onOutput: () => {} });
  t.eval("set i 0; while 1 {puts $i; incr i}");
  t.computeLimit = null;
  const i = t.eval("set i").result;
  t.close();
  return i;
};
const a = await stop(strict);
const b = await stop(host);
check(a === b, `the compute limit stops at ${a} in ztcl.wasm and at ${b} in ztcl-host.wasm`);

if (failed) process.exit(1);
console.log("wasm host ok");
