// The playground page: an editor, Run and Stop, and the limits.
// SPDX-License-Identifier: BSD-2-Clause
import { WorkerInterp } from "./ztcl.mjs";
import { presets } from "./presets.mjs";

const $ = (id) => document.getElementById(id);
const code = $("code");
const out = $("out");
const status = $("status");
const run = $("run");
const stop = $("stop");
const preset = $("preset");

const tcl = new WorkerInterp(new URL("ztcl.wasm", import.meta.url));
let busy = false;

for (const [i, p] of presets.entries()) preset.add(new Option(p.name, String(i)));
const start = Number(new URLSearchParams(location.search).get("example") ?? 0);
preset.value = String(presets[start] ? start : 0);
code.value = presets[Number(preset.value)].code;
preset.addEventListener("change", () => {
  code.value = presets[Number(preset.value)].code;
  out.textContent = "";
});

function line(text, cls) {
  const span = document.createElement("span");
  span.className = cls;
  span.textContent = text;
  out.append(span);
}

function setBusy(on) {
  busy = on;
  run.disabled = on;
  stop.disabled = !on;
}

async function go() {
  if (busy) return;
  const steps = Math.max(1, Math.floor(Number($("steps").value) || 1));
  const mib = Math.min(1024, Math.max(1, Math.floor(Number($("mem").value) || 1)));
  tcl.stepLimit = steps;
  tcl.memLimit = mib * 1024 * 1024;
  tcl.reset();
  out.textContent = "";
  status.textContent = "Running";
  setBusy(true);
  const t0 = performance.now();
  let r;
  try {
    r = await tcl.eval(code.value);
  } catch (e) {
    r = { ok: false, result: `the worker failed: ${e.message}`, output: "" };
  }
  const ms = performance.now() - t0;
  setBusy(false);
  if (r.output) out.append(r.output);
  if (r.result === "stopped" && !r.ok) {
    line("Stopped.\n", "err");
    status.textContent = `Stopped after ${ms.toFixed(0)} ms`;
    return;
  }
  if (r.ok) {
    if (r.result !== "") line(`=> ${r.result}\n`, "res");
  } else {
    line(`error: ${r.result}\n`, "err");
  }
  const mem = r.memorySize ? `, ${(r.memorySize / 1048576).toFixed(0)} MiB linear memory` : "";
  status.textContent = `${r.ok ? "OK" : "Error"} in ${ms.toFixed(0)} ms${mem}`;
}

run.addEventListener("click", go);
stop.addEventListener("click", () => tcl.stop());

code.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    go();
    return;
  }
  if (e.key !== "Tab" || e.altKey || e.ctrlKey || e.metaKey) return;
  e.preventDefault();
  const { selectionStart: a, selectionEnd: b, value } = code;
  const first = value.lastIndexOf("\n", a - 1) + 1;
  if (a === b && !e.shiftKey) {
    code.setRangeText("    ", a, b, "end");
    return;
  }
  // Indent or outdent each selected line.
  const block = value.slice(first, b);
  const next = e.shiftKey ? block.replace(/^ {1,4}/gm, "") : block.replace(/^/gm, "    ");
  code.setRangeText(next, first, b, "select");
});

// Load the module now, so the first Run has no wait.
tcl.eval("info patchlevel").then((r) => {
  status.textContent = r.ok ? `Ready · Tcl ${r.result}` : "Error";
});
