// Checks the types of the package with tsc. run.mjs puts the name of
// the package in place of the name below.
import { compile, Interp, WorkerInterp, run, wasmURL, type EvalResult, type InterpOptions } from "{{name}}";
import type { WorkerRequest, WorkerResponse } from "{{name}}/worker";

const options: InterpOptions = { computeLimit: 1_000_000, memLimit: 64 << 20, onOutput: (t: string) => console.log(t) };
const module: WebAssembly.Module = await compile(wasmURL());
const tcl: Interp = await Interp.create(module, options);
const tcl2: Interp = await Interp.create(options);
const r: EvalResult = tcl.eval("expr {1 + 1}");
const ok: boolean = r.ok && tcl2.memorySize > 0;
tcl.computeLimit = null;
const size: number = tcl.bundleSize;
tcl.close();
const bundled: EvalResult = await run("app.wasm", { computeLimit: 1000, allow: ["file"] });
const tcl3 = await Interp.create("app.wasm", { allow: ["file"] });
const rr: EvalResult = tcl3.run();
const webOptions: InterpOptions = { allow: ["dom", "event", "web:serial"], web: { Bridge: class {} }, webRoot: globalThis, webComputeLimit: 1000 };
const w = new WorkerInterp({ computeLimit: 10 });
const wr = await w.eval("set x 1");
const n: number | undefined = wr.memorySize;
w.stop();
const msg: WorkerRequest = { id: 1, script: "set x 1" };
const answer: WorkerResponse = { id: 1, error: "x" };
const { ThreadInterp } = await import("{{name}}/threads");
const t = await ThreadInterp.create({ mode: "auto", allow: ["thread", "event"], limits: { maxThreads: 4 } });
const tr = await t.eval("thread::names");
t.close();
const tok: boolean = tr.ok && t.mode === "shared";
export { ok, n, msg, answer, tok, size, bundled, rr };
