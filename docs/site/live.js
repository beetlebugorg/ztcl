// SPDX-License-Identifier: BSD-2-Clause
// The live examples of the docs pages. tools/build-docs.py writes a
// <figure class="live-demo"> for each `tcl` block after a line
// `<!-- live -->`. This file makes the code an editor, with a text area
// over a highlighted copy of the code, and runs it in a WorkerInterp of
// playground/ztcl.mjs. The page loads the module only when an example
// comes near the viewport. Each example has its own worker, with a compute
// limit and no capability, so a script has no file, network, or process
// access, and an endless loop stops at the compute limit or at Stop.
//
// The example runs again 400 ms after the last key, in a new
// interpreter. The output and the result show under the code.
//
// The editor and the highlighter come from docs/site/live.js of ztk
// (github.com/beetlebugorg/ztk), BSD-2-Clause.

const base = new URL("../playground/", import.meta.url);
const params = new URLSearchParams(location.search);
const LIMIT = 50_000_000;
let lib = null;
const load = () => (lib ??= import(new URL("ztcl.mjs", base).href));

const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
const span = (cls, s) => `<span class="${cls}">${esc(s)}</span>`;
export function highlight(src) {
  let out = "", i = 0, start = true;
  const n = src.length;
  const wordStart = () => i === 0 || /[\s{[;]/.test(src[i - 1]);
  while (i < n) {
    const ch = src[i];
    if (start && ch === "#") {
      let j = src.indexOf("\n", i);
      if (j < 0) j = n;
      out += span("c", src.slice(i, j)); i = j; continue;
    }
    if (ch === "\n" || ch === ";" || ch === "[" || ch === "{") { out += esc(ch); i++; start = true; continue; }
    if (ch === " " || ch === "\t") { out += ch; i++; continue; }
    if (ch === '"') {
      let j = i + 1;
      while (j < n && src[j] !== '"') j += src[j] === "\\" ? 2 : 1;
      out += span("s", src.slice(i, j + 1)); i = j + 1; start = false; continue;
    }
    if (ch === "$") {
      const m = /^\$(\{[^}]*\}|[\w:]+(\([^)\s]*\))?)/.exec(src.slice(i));
      if (m) { out += span("v", m[0]); i += m[0].length; start = false; continue; }
    }
    if (wordStart()) {
      const m = /^[^\s;{}[\]"$]+/.exec(src.slice(i));
      if (m) {
        const w = m[0];
        const cls = start ? "k" : /^-[a-z]/.test(w) ? "o" : /^-?\d+(\.\d+)?$/.test(w) ? "n" : null;
        out += cls ? span(cls, w) : esc(w);
        i += w.length; start = false; continue;
      }
    }
    if (ch === "\\" && i + 1 < n) { out += esc(src.slice(i, i + 2)); i += 2; continue; }
    out += esc(ch); i++; start = false;
  }
  return out;
}

class Example {
  constructor(fig) {
    this.fig = fig;
    this.original = fig.querySelector(".ld-code code").textContent;
    const box = fig.querySelector(".ld-code");
    this.hl = document.createElement("pre");
    this.hl.className = "ld-hl";
    this.hl.setAttribute("aria-hidden", "true");
    this.ta = document.createElement("textarea");
    this.ta.spellcheck = false;
    this.ta.autocapitalize = "off";
    this.ta.setAttribute("aria-label", "The Tcl code of the example. Tab puts in four spaces; press Escape and then Tab to leave.");
    this.ta.value = this.original;
    box.replaceChildren(this.hl, this.ta);
    this.paint();
    let timer = 0, tabOut = false;
    this.ta.addEventListener("input", () => {
      this.paint();
      clearTimeout(timer);
      timer = setTimeout(() => this.run(), 400);
    });
    this.ta.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { tabOut = true; return; }
      if (e.key === "Tab" && !tabOut && !e.shiftKey) {
        e.preventDefault();
        document.execCommand("insertText", false, "    ");
      }
      tabOut = false;
    });
    this.out = fig.querySelector(".ld-out");
    const bar = fig.querySelector(".ld-bar");
    const button = (text, f) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = text;
      b.addEventListener("click", f);
      bar.appendChild(b);
      return b;
    };
    button("Run", () => this.run());
    this.stop = button("Stop", () => this.tcl?.stop());
    this.stop.disabled = true;
    button("Reset", () => { this.ta.value = this.original; this.paint(); this.run(); });
    this.info = document.createElement("span");
    this.info.className = "ld-hud";
    this.info.textContent = `Compute limit ${LIMIT.toLocaleString("en-US")}`;
    bar.appendChild(this.info);
  }

  paint() {
    this.hl.innerHTML = highlight(this.ta.value) + " ";
  }

  async run() {
    const seq = (this.seq = (this.seq || 0) + 1);
    this.fig.dataset.live = this.fig.dataset.live === "1" ? "1" : "loading";
    let m;
    try {
      m = await load();
    } catch (e) {
      this.fig.dataset.live = "failed";
      this.out.textContent = `The interpreter did not load: ${e.message}`;
      return;
    }
    this.tcl?.stop();
    const tcl = (this.tcl = new m.WorkerInterp(new URL("ztcl.wasm", base), { computeLimit: LIMIT }));
    let text = "";
    tcl.onOutput = (t) => { text += t; };
    this.stop.disabled = false;
    const t0 = performance.now();
    const r = await tcl.eval(this.ta.value);
    const ms = performance.now() - t0;
    if (seq !== this.seq) return;
    this.stop.disabled = true;
    tcl.stop();
    this.fig.dataset.live = "1";
    this.fig.dataset.ok = String(r.ok);
    const output = (r.output ?? "") || text;
    this.out.replaceChildren();
    if (output) this.out.append(output.endsWith("\n") ? output : output + "\n");
    if (r.result !== "" || !r.ok) {
      const res = document.createElement("span");
      res.className = r.ok ? "ld-result" : "ld-error";
      res.textContent = r.ok ? `=> ${r.result}` : `error: ${r.result}`;
      this.out.append(res);
    }
    this.info.textContent = `${ms.toFixed(1)} ms in a worker · compute limit ${LIMIT.toLocaleString("en-US")}`;
    return r;
  }
}

const examples = [...document.querySelectorAll("figure.live-demo")].map((f) => new Example(f));
if (params.has("snippettest")) {
  // The test hook: each example runs, and the first one gets an edit.
  window.ztclLiveDocs = (async () => {
    const out = { live: [], checks: {} };
    for (const e of examples) {
      const r = await e.run();
      out.live.push(`${e.fig.id}:${e.fig.dataset.live}:${r?.ok}:${e.out.textContent.slice(0, 40)}`);
    }
    const e = examples[0];
    if (e) {
      e.ta.value = "puts [expr {6 * 7}]";
      await e.run();
      out.checks.edit = e.out.textContent.trim();
      e.ta.value = "while 1 {}";
      const r = await e.run();
      out.checks.limit = r.ok ? "no" : "yes";
    }
    const pre = document.createElement("pre");
    pre.id = "result";
    pre.textContent = JSON.stringify(out);
    document.body.appendChild(pre);
  })();
} else if ("IntersectionObserver" in window && typeof WebAssembly === "object") {
  const io = new IntersectionObserver((es) => {
    for (const en of es) {
      if (!en.isIntersecting) continue;
      io.unobserve(en.target);
      examples.find((x) => x.fig === en.target).run();
    }
  }, { rootMargin: "200px" });
  for (const e of examples) io.observe(e.fig);
}
