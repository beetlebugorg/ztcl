// Runs a test script of tests/cext on the WebAssembly path. `load
// DIR/NAME.so` of the script loads DIR/NAME.wasm, a package that
// tools/cext/wasm-check.sh built. The text of each `puts` goes to
// stdout, and an error of the script goes to stdout as tclsh prints it.
//
//   node tools/cext/wasm-check.mjs zig-out/lib/ztcl-host.wasm SCRIPT
//
// SPDX-License-Identifier: BSD-2-Clause
import { readFileSync } from "node:fs";
import { Interp } from "../../web/ztcl.mjs";

const [lib, script] = process.argv.slice(2);
const tcl = await Interp.create(readFileSync(lib), {
  onOutput: (t) => process.stdout.write(t),
  packages: (file) => readFileSync(file.replace(/\.so$/, ".wasm")),
});
const r = tcl.eval(readFileSync(script, "utf8"));
if (!r.ok) process.stdout.write(`${r.result}\n`);
tcl.close();
