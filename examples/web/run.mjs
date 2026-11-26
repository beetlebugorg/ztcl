#!/usr/bin/env node
// Runs a Tcl script with ztcl.wasm in Node.js, with a compute limit and a
// memory limit.
//
//   node examples/web/run.mjs [--compute N] [--mem MiB] [--wasm path] script.tcl
//
// The exit code is 0 on success and 1 on an error of the script.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import { Interp } from "../../web/ztcl.mjs";

const args = process.argv.slice(2);
let units = 10_000_000;
let mem = 64;
let wasm = new URL("../../zig-out/lib/ztcl.wasm", import.meta.url);
let file = null;
while (args.length) {
  const a = args.shift();
  if (a === "--compute") units = Number(args.shift());
  else if (a === "--mem") mem = Number(args.shift());
  else if (a === "--wasm") wasm = args.shift();
  else file = a;
}
if (!file) {
  console.error("usage: run.mjs [--compute N] [--mem MiB] [--wasm path] script.tcl");
  process.exit(2);
}

const tcl = await Interp.create(wasm, {
  computeLimit: units,
  memLimit: mem * 1024 * 1024,
  onOutput: (text) => process.stdout.write(text),
});
const t0 = performance.now();
const r = tcl.eval(fs.readFileSync(file, "utf8"));
const ms = performance.now() - t0;
if (!r.ok) {
  console.error(`error: ${r.result}`);
  process.exitCode = 1;
}
console.error(`${ms.toFixed(1)} ms, ${(tcl.memorySize / 1048576).toFixed(1)} MiB of linear memory`);
tcl.close();
