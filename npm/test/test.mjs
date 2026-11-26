// Tests the npm package as a project installs it. npm/test/run.mjs
// copies this file into a new project, installs the package tarball,
// and runs `node test.mjs`. The name of the package comes from the
// dependencies of that project.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";

const deps = JSON.parse(fs.readFileSync(new URL("./package.json", import.meta.url), "utf8")).dependencies;
const name = Object.keys(deps).find((d) => d.endsWith("/ztcl") || d === "ztcl");
const { compile, Interp, WorkerInterp, run, wasmURL } = await import(name);

let failed = 0;
let passed = 0;
const check = (ok, what) => {
  if (ok) passed++;
  else {
    console.error(`FAIL ${what}`);
    failed++;
  }
};

// The Node.js example of the README.
{
  const tcl = await Interp.create({ computeLimit: 1_000_000, memLimit: 64 << 20 });
  const r = tcl.eval("proc sq {x} {expr {$x * $x}}; sq 12");
  check(r.ok && r.result === "144", "README Node.js example");
  tcl.close();
}

// The default module is the ztcl.wasm file of the package.
check(wasmURL().href === import.meta.resolve(`${name}/ztcl.wasm`), "wasmURL is the file of the package");
check(fs.statSync(wasmURL()).size > 100_000, "ztcl.wasm is in the package");
check(fs.existsSync(new URL(import.meta.resolve(`${name}/worker`))), "the worker entry resolves");
const pkg = JSON.parse(fs.readFileSync(new URL(import.meta.resolve(`${name}/package.json`)), "utf8"));
check(pkg.name === name && /^\d+\.\d+\.\d+/.test(pkg.version), "package.json entry");

// One module for many interpreters, a module from bytes, and a file path.
const module = await compile();
check(module instanceof WebAssembly.Module, "compile() with no source");
check((await compile(fs.readFileSync(wasmURL()))) instanceof WebAssembly.Module, "compile(bytes)");
check((await compile(wasmURL().pathname)) instanceof WebAssembly.Module, "compile(file path)");

// Output, results, and errors.
let out = "";
const tcl = await Interp.create(module, { computeLimit: 10_000, memLimit: 8 << 20, onOutput: (t) => (out += t) });
let r = tcl.eval("puts hello; expr {6 * 7}");
check(r.ok && r.result === "42" && r.output === "hello\n" && out === "hello\n", "eval, result, and onOutput");
r = tcl.eval("set nope");
check(!r.ok && r.result.startsWith("can't read \"nope\""), "error message");
check(tcl.eval("set x 5; incr x").result === "6" && tcl.eval("set x").result === "6", "state stays between evals");

// The compute limit applies to each eval, and catch cannot catch it.
r = tcl.eval("set i 0; catch {while 1 {incr i}}");
check(!r.ok && r.result === "compute limit reached", "compute limit");
tcl.computeLimit = null;
check(tcl.eval("set n 0; while {$n < 100000} {incr n}; set n").result === "100000", "no compute limit");
tcl.computeLimit = 10_000n;
check(!tcl.eval("while 1 {}").ok, "compute limit as a BigInt");

// The memory limit.
tcl.computeLimit = 10_000_000;
tcl.memLimit = 16 << 20;
r = tcl.eval("set s x; catch {while 1 {append s $s}}");
check(!r.ok && r.result === "the script used too much memory", "memory limit");
check(tcl.memorySize < 64 << 20, "linear memory near the cap");
check(tcl.memLimit === 16 << 20, "memLimit getter");

// No command reaches the host.
for (const cmd of ["open /etc/passwd", "exec ls", "socket localhost 80", "clock seconds"]) {
  check(!tcl.eval(cmd).ok, `no host access: ${cmd}`);
}
tcl.close();
let closed = false;
try {
  tcl.eval("set x");
} catch {
  closed = true;
}
check(closed, "eval after close throws");

// Each interpreter has its own instance.
const a = await Interp.create(module);
const b = await Interp.create(module);
a.eval("set v a");
check(!b.eval("set v").ok, "interpreters are separate");

// WorkerInterp needs a browser. Its constructor works in Node.js.
const w = new WorkerInterp({ computeLimit: 5 });
check(w.wasm === wasmURL().href && w.computeLimit === 5, "WorkerInterp default module");

// A bundle of `ztcl build --wasm`. app.out is the output of the native
// ztcl. The limits hold, and the files need the capability.
{
  const want = fs.readFileSync(new URL("./app.out", import.meta.url), "utf8");
  let out = "";
  const r = await run("app.wasm", { computeLimit: 100_000, allow: ["file"], onOutput: (t) => (out += t) });
  check(r.ok && r.output === want && out === want, "bundle output equals ztcl");
  const no = await run("app.wasm");
  check(!no.ok && no.result.includes('invalid command name "open"'), "bundle files need the capability");
  const few = await run("app.wasm", { computeLimit: 2, allow: ["file"] });
  check(!few.ok && few.result.endsWith("compute limit reached"), "bundle compute limit");
  const t = await Interp.create("app.wasm", { allow: ["file"] });
  check(t.bundleSize > 0 && t.eval("source //zipfs:/app/lib.tcl; sq 9").result === "81", "bundle source under the mount");
  t.close();
}

// The threads entry: Node.js has the shared mode.
{
  const { ThreadInterp } = await import(`${name}/threads`);
  const t = await ThreadInterp.create({ allow: ["thread"] });
  const r = await t.eval("set t [thread::create]; thread::send $t {expr {6 * 7}}");
  check(t.mode === "shared" && r.ok && r.result === "42", "ThreadInterp send");
  t.close();
}

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
