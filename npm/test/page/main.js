// The browser test of the package. run.mjs puts the name of the
// package, or a URL for the no-build test, in place of the name below.
import { Interp, WorkerInterp, run } from "{{import}}";

async function main() {
  const res = {};
  const tcl = await Interp.create({ stepLimit: 100_000, memLimit: 16 << 20 });
  res.eval = tcl.eval("expr {6 * 7}").result;
  res.steps = tcl.eval("while 1 {}").result;
  const w = new WorkerInterp({ memLimit: 64 << 20 });
  res.worker = (await w.eval("set n 0; for {set i 0} {$i < 1000} {incr i} {incr n $i}; set n")).result;
  const forever = w.eval("while 1 {}");
  setTimeout(() => w.stop(), 300);
  res.stopped = (await forever).result;
  res.after = (await w.eval("expr {1 + 1}")).result;
  w.stop();
  // A bundle of `ztcl build --wasm` next to the page.
  const b = await run(new URL("./app.wasm", location.href), { stepLimit: 100_000, memLimit: 16 << 20, allow: ["file"] });
  res.bundle = b.ok ? b.output : `error: ${b.result}`;
  return res;
}

main().then(
  (res) => (document.getElementById("result").textContent = JSON.stringify(res)),
  (e) => (document.getElementById("result").textContent = JSON.stringify({ error: String(e && e.stack || e) })),
);
