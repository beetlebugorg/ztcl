// Runs one SQLite test file in ztcl-host.wasm (-Dcext-wasm) with the
// binding of libztclstubs.a. The script loads the package with the
// `load` command of web/ztcl.mjs. The host commands file, glob, and
// source of host.mjs are JavaScript commands of defineCommand, on the
// work folder. The package reaches the work folder through the WASI of
// Node.js.
//   node bridge-test.mjs ztcl-host.wasm sqlite.wasm WORKDIR script.tcl [args]
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import path from "node:path";
import { WASI } from "node:wasi";
import { Interp } from "../../web/ztcl.mjs";

const [lib, pkgPath, work, script, ...scriptArgs] = process.argv.slice(2);
fs.mkdirSync(work, { recursive: true });
const wasi = new WASI({ version: "preview1", preopens: { "/": work }, returnOnExit: true });
const pkgMod = new WebAssembly.Module(fs.readFileSync(pkgPath));
const packages = (file) => (path.basename(file) === path.basename(pkgPath)
  ? { module: pkgMod, wasi: { ...wasi.wasiImport, initialize: (inst) => wasi.initialize(inst) } }
  : null);
const it = await Interp.create(fs.readFileSync(lib), { allow: ["clock"], onOutput: (s) => process.stdout.write(s), packages });
const zeval = (s) => it.eval(s);

function quote(s) {
  if (s === "") return "{}";
  if (!/[\s{}\[\]$"\\;]/.test(s) && s[0] !== "#") return s;
  let depth = 0, ok = !s.endsWith("\\");
  for (const c of s) {
    if (c === "{") depth++;
    else if (c === "}" && --depth < 0) ok = false;
  }
  if (ok && depth === 0 && !/\\/.test(s)) return "{" + s + "}";
  return s.replace(/([\s{}\[\]$"\\;])/g, (m) => (m === "\n" ? "\\n" : m === "\t" ? "\\t" : "\\" + m)).replace(/^#/, "\\#");
}
// Commands of the host for the test scripts, in place of the file and
// channel commands that ztcl-host.wasm does not have.
const W = (n) => path.resolve(work, n);
const host = {
  file: (a) => {
    const [sub, ...r] = a;
    const args = r.filter((x) => !x.startsWith("-") || x === "-");
    switch (sub) {
      case "exists": return fs.existsSync(W(args[0])) ? "1" : "0";
      case "delete": for (const f of args) fs.rmSync(W(f), { force: true, recursive: true }); return "";
      case "size": return String(fs.statSync(W(args[0])).size);
      case "join": return path.posix.join(...args);
      case "tail": return path.posix.basename(args[0]);
      case "dirname": return path.posix.dirname(args[0]);
      case "extension": return path.posix.extname(args[0]);
      case "rootname": return args[0].slice(0, args[0].length - path.posix.extname(args[0]).length);
      case "normalize": return path.resolve(work, args[0]);
      case "isdirectory": return fs.existsSync(W(args[0])) && fs.statSync(W(args[0])).isDirectory() ? "1" : "0";
      case "isfile": return fs.existsSync(W(args[0])) && fs.statSync(W(args[0])).isFile() ? "1" : "0";
      case "mkdir": for (const f of args) fs.mkdirSync(W(f), { recursive: true }); return "";
      case "copy": fs.copyFileSync(W(args[0]), W(args[1])); return "";
      case "rename": fs.renameSync(W(args[0]), W(args[1])); return "";
      case "split": return args[0].split("/").filter((x, i) => x || i === 0).map((x) => x || "/").map(quote).join(" ");
      case "attributes": case "readable": case "writable": return "1";
      case "nativename": return args[0];
      case "mtime": return String(Math.floor(fs.statSync(W(args[0])).mtimeMs / 1000));
      default: throw new Error(`file ${sub}: not in the spike host`);
    }
  },
  glob: (a) => {
    const pats = a.filter((x) => !x.startsWith("-"));
    const out = [];
    for (const pat of pats) {
      const re = new RegExp("^" + pat.replace(/[.+^${}()|\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, ".") + "$");
      for (const f of fs.readdirSync(W(path.posix.dirname(pat)))) {
        const full = path.posix.join(path.posix.dirname(pat), f).replace(/^\.\//, "");
        if (re.test(full) || re.test(f)) out.push(full);
      }
    }
    return out.map(quote).join(" ");
  },
  source: (a) => {
    const f = a[a.length - 1];
    const text = fs.readFileSync(fs.existsSync(f) ? f : W(f), "utf8");
    const r = zeval(text);
    if (r.code === 1) throw new Error(r.result);
    return r.result;
  },
  flush: () => "",
  fconfigure: () => "",
  exit: (a) => { flush(); process.exit(Number(a[0] || 0)); },
};


// The output that the interp keeps until the end of a top eval.
function flush() {
  const x = it.x;
  const n = x.ztcl_output_len(it.h);
  if (n) process.stdout.write(new Uint8Array(x.memory.buffer, x.ztcl_output_ptr(it.h), n));
  x.ztcl_output_clear(it.h);
}

for (const [name, fn] of Object.entries(host)) it.defineCommand(name, fn);
it.eval(`set ::spike ${quote(process.env.SPIKE || "")}; set ::shimdir ${quote(path.dirname(path.resolve(script)))}`);
it.eval(`set argv0 ${quote(script)}; set argv ${quote(scriptArgs.map(quote).join(" "))}; set argc ${scriptArgs.length}`);
const t0 = performance.now();
const r = it.eval(fs.readFileSync(script, "utf8"));
if (!r.ok) process.stdout.write("ERROR: " + r.result + "\n" + (process.env.CEXT_DEBUG ? it.eval("set ::errorInfo").result + "\n" : ""));
process.stderr.write(`time ${(performance.now() - t0).toFixed(1)} ms\n`);
