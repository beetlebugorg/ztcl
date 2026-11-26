// Runs a Tcl script in ztcl-host.wasm with a C package of
// libztclstubs.a, through Interp.loadPackage of web/ztcl.mjs. The
// package reaches the current folder through the WASI of Node.js.
//   node bridge.mjs ztcl-host.wasm package.wasm script.tcl [var=value ...]
// SPDX-License-Identifier: BSD-2-Clause
import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";
import { Interp } from "../../web/ztcl.mjs";

const [lib, pkg, script, ...sets] = process.argv.slice(2);
const it = await Interp.create(readFileSync(lib), { allow: ["clock"], onOutput: (s) => process.stdout.write(s) });
const wasi = new WASI({ version: "preview1", preopens: { "/": process.cwd() } });
const imports = wasi.getImportObject().wasi_snapshot_preview1;
await it.loadPackage(readFileSync(pkg), { init: "Sqlite3_Init", wasi: { ...imports, initialize: (inst) => wasi.initialize(inst) } });
for (const s of sets) {
  const i = s.indexOf("=");
  it.eval(`set ::${s.slice(0, i)} {${s.slice(i + 1)}}`);
}
const r = it.eval(readFileSync(script, "utf8"));
if (!r.ok) {
  console.error(r.result);
  process.exit(1);
}
