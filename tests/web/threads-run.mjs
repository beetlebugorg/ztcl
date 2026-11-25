// Runs one test file of tests/thread/ or tests/web/ in a ThreadInterp of
// web/ztcl-threads.mjs. tools/wasm-threads.mjs uses it in Node.js and
// in the test page of Chromium.
// SPDX-License-Identifier: BSD-2-Clause

export async function runPlan(plan, { mode, wasm, module = "./ztcl-threads.mjs", timeout = Number(globalThis.process?.env?.THREAD_TIMEOUT ?? 120_000) }) {
  const { ThreadInterp } = await import(module);
  let timer;
  const late = new Promise((res) => (timer = setTimeout(() => res("timeout"), timeout)));
  try {
    const r = await Promise.race([run(ThreadInterp, plan, mode, wasm), late]);
    return r === "timeout" ? { file: plan.file, ok: false, result: "timeout", output: plan.output } : r;
  } finally {
    clearTimeout(timer);
    plan.interp?.close();
  }
}

async function run(ThreadInterp, plan, mode, wasm) {
  plan.output = "";
  const t = await ThreadInterp.create({ mode, wasm, asyncWasm: wasm, allow: plan.allow, limits: plan.limits, onOutput: (o) => (plan.output += o) });
  plan.interp = t;
  try {
    // A line "# ---- wait: EXPR" ends a step. The next step runs when
    // EXPR is true, at most 10 seconds later.
    const steps = plan.script.split(/^# ---- wait: (.*)$/m);
    let r = await t.eval(steps[0]);
    for (let i = 1; r.ok && i < steps.length; i += 2) {
      const end = Date.now() + 10_000;
      for (;;) {
        const c = await t.eval(`expr ${steps[i]}`);
        if (c.ok && c.result === "1") break;
        if (Date.now() > end) return { file: plan.file, ok: false, result: `timeout: ${steps[i]} ${c.result}`, output: plan.output };
        await new Promise((res) => setTimeout(res, 20));
      }
      r = await t.eval(steps[i + 1]);
    }
    return { file: plan.file, ok: r.ok, result: r.result, output: plan.output };
  } catch (e) {
    return { file: plan.file, ok: false, result: String(e?.message ?? e), output: plan.output };
  }
}
