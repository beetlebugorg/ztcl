// Tests `ztcl build --wasm` and the bundle API of web/ztcl.mjs in
// Node.js. The output of each bundle must equal the output of `ztcl`.
//   node tools/wasm-bundle.mjs zig-out/bin/ztcl zig-out/lib/ztcl.wasm
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { Interp, run } from "../web/ztcl.mjs";

const [ztcl, wasm] = process.argv.slice(2).map((p) => path.resolve(p));
const work = fs.mkdtempSync(path.join(os.tmpdir(), "ztcl-bundle-"));
let failed = 0;
const check = (ok, what, got) => {
  if (!ok) {
    console.error(`FAIL ${what}${got === undefined ? "" : `: ${JSON.stringify(got)}`}`);
    failed++;
  }
};

const files = {
  "lib.tcl": "proc sq {x} {expr {$x * $x}}\nputs [sq 12]\n",
  "app.tcl": [
    'puts "sq [sq 3]"',
    "set d [dict create a 1 b 2]",
    "dict for {k v} $d {puts \"$k=$v\"}",
    "puts [lsort -decreasing {3 1 2}]",
    "puts [string map {a A} banana]",
    "puts [format %.3f [expr {acos(-1)}]]",
    "set n 0; for {set i 0} {$i < 1000} {incr i} {incr n $i}; puts $n",
    "",
  ].join("\n"),
  "files.tcl": [
    "source data/b.tcl",
    "puts $fromdata",
    "set f [open data/a.txt]",
    "while {[gets $f line] >= 0} {puts \"line: $line\"}",
    "puts [eof $f]",
    "close $f",
    "set f [open data/a.txt r]",
    "puts [string length [read $f]]",
    "close $f",
    "",
  ].join("\n"),
  "bad.tcl": "puts before\nset nope\nputs after\n",
  "forever.tcl": "set i 0\nwhile 1 {incr i}\n",
  "bomb.tcl": "set s x\nwhile 1 {append s $s}\n",
  "data/a.txt": "one\ntwo\n",
  "data/b.tcl": "set fromdata 7\n",
};
for (const [name, text] of Object.entries(files)) {
  fs.mkdirSync(path.dirname(path.join(work, name)), { recursive: true });
  fs.writeFileSync(path.join(work, name), text);
}

const native = (args) => spawnSync(ztcl, args, { cwd: work, encoding: "utf8" });
const build = (out, ...args) => execFileSync(ztcl, ["build", "--wasm", "--base", wasm, "-o", out, ...args], { cwd: work, encoding: "utf8" });
const bundle = (name) => path.join(work, name);

try {
  // The scripts run in order, and the output equals `ztcl lib.tcl app.tcl`.
  const said = build("app.wasm", "lib.tcl", "app.tcl");
  const plain = fs.statSync(wasm).size;
  const size = fs.statSync(bundle("app.wasm")).size;
  console.log(`app.wasm: ${size} bytes, ztcl.wasm: ${plain} bytes, +${size - plain}`);
  check(said.startsWith("app.wasm: ") && said.includes(`ztcl.wasm: ${plain} bytes`), "the size line of build", said);
  const want = native(["lib.tcl", "app.tcl"]);
  check(want.status === 0, "native ztcl runs the scripts", want.stdout);
  let out = "";
  const tcl = await Interp.create(bundle("app.wasm"), { stepLimit: 1_000_000, onOutput: (t) => (out += t) });
  check(tcl.bundleSize > 0, "bundleSize");
  let r = tcl.run();
  check(r.ok && r.output === want.stdout && out === want.stdout, "bundle output equals ztcl", r);
  // The interpreter stays usable after run().
  check(tcl.eval("sq 5").result === "25", "eval after run");
  tcl.close();
  r = await run(bundle("app.wasm"));
  check(r.ok && r.output === want.stdout, "run() helper", r);

  // An error stops the scripts. The result is the line of `ztcl`.
  build("bad.wasm", "bad.tcl", "app.tcl");
  const nb = native(["bad.tcl", "app.tcl"]);
  r = await run(bundle("bad.wasm"));
  check(!r.ok && r.output === "before\n" && `${r.output}${r.result}\n` === nb.stdout && nb.status === 1, "error stops the bundle", [r, nb.stdout]);

  // The step limit and the memory limit hold.
  build("forever.wasm", "forever.tcl");
  r = await run(bundle("forever.wasm"), { stepLimit: 100_000 });
  check(!r.ok && r.result === "forever.tcl:2: step limit reached", "step limit", r);
  build("bomb.wasm", "bomb.tcl");
  const big = await Interp.create(bundle("bomb.wasm"), { stepLimit: 10_000_000, memLimit: 16 << 20 });
  r = big.run();
  check(!r.ok && r.result.endsWith("the script used too much memory"), "memory limit", r);
  check(big.memorySize <= 4 * (16 << 20), "linear memory near the cap", big.memorySize);
  big.close();

  // The embedded files: source and open with the file capability. The
  // output equals `ztcl` with a root folder.
  build("files.wasm", "--embed", "data", "files.tcl");
  const nf = native(["--allow", "channels,file", "--root", work, "files.tcl"]);
  r = await run(bundle("files.wasm"), { allow: ["file"] });
  check(nf.status === 0 && r.ok && r.output === nf.stdout, "embedded files equal ztcl --allow file", [r, nf.stdout]);
  const f = await Interp.create(bundle("files.wasm"), { allow: ["file"] });
  r = f.eval("set c [open //zipfs:/app/data/a.txt]; set t [read -nonewline $c]; close $c; set t");
  check(r.ok && r.result === "one\ntwo", "open under the mount", r);
  r = f.eval("source //zipfs:/app/files.tcl");
  check(r.ok && r.output === nf.stdout, "source of a script of the bundle", r);
  for (const [cmd, msg] of [
    ["open /etc/passwd", 'couldn\'t open "/etc/passwd": no such file or directory'],
    ["open data/a.txt w", 'couldn\'t open "data/a.txt": read-only file system'],
    ["source ../../etc/passwd", 'couldn\'t read file "../../etc/passwd": no such file or directory'],
    ["read zipfs9", 'can not find channel named "zipfs9"'],
  ]) {
    r = f.eval(cmd);
    check(!r.ok && r.result === msg, `refused: ${cmd}`, r);
  }
  f.close();
  // With no capability, the bundle has no file command.
  r = await run(bundle("files.wasm"));
  check(!r.ok && r.result === 'files.tcl:1: invalid command name "source"', "no file command without the capability", r);
  let threw = false;
  try {
    await Interp.create(bundle("files.wasm"), { allow: ["exec"] });
  } catch {
    threw = true;
  }
  check(threw, "allow refuses another capability");

  // The plain module has no bundle.
  const p = await Interp.create(wasm);
  check(p.bundleSize === 0, "plain module has bundleSize 0");
  threw = false;
  try {
    p.run();
  } catch {
    threw = true;
  }
  check(threw, "run() on a plain module throws");
  p.close();

  // A bundle cannot be the base of a bundle.
  const again = spawnSync(ztcl, ["build", "--wasm", "--base", bundle("app.wasm"), "-o", "x.wasm", "app.tcl"], { cwd: work, encoding: "utf8" });
  check(again.status === 1 && again.stdout.includes("a bundle already"), "a bundle as the base", again.stdout);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}

if (failed) process.exit(1);
console.log("wasm bundle ok");
