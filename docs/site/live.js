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
// interpreter. The output and the result show under the code. Until the
// first run, the output from the page shows there.
//
// An example of `dom` (data-dom on the figure) runs in the page, in an
// Interp of ztcl-host.wasm with the capabilities `dom` and `event`. Its
// stage (.ld-stage) is the root element, and each run starts from the
// HTML of the stage again. The output of its event scripts shows under
// the stage. It has no Stop: each eval and each event script has a
// compute limit.
//
// An example of ztcl::vt (data-term on the figure) gets a "Screen"
// button. The button shows the screen of the last terminal of the
// example: an execution trace on ztcl::vt keeps the handle of each `new`
// and reads the cells before a `delete`, and the page renders the cells
// with their colors and attributes. The screen shows only after a click,
// so the layout does not move by itself.
//
// An example of ztcl::typeset or ztcl::pdf (data-wasm on the figure)
// runs in ztcl-shell.wasm, which has them, with the capability `file`.
// The fonts that it names (data-files) come from book/fonts/ of the site,
// and `open book/fonts/NAME.ttf rb` reads them. The files that it writes
// show under the output: each SVG image inline, side by side, after the
// page drops its scripts, event handlers, and links, and each PDF in a
// viewer, with a link to open it in a tab and a link to download it.
//
// The editor and the highlighter come from docs/site/live.js of ztk
// (github.com/beetlebugorg/ztk), BSD-2-Clause.

const base = new URL("../playground/", import.meta.url);
const params = new URLSearchParams(location.search);
const LIMIT = 50_000_000;
let lib = null;
const load = () => (lib ??= import(new URL("ztcl.mjs", base).href));

// The fonts of the site, by name: each one is fetched once for the page.
const site = new URL("../", import.meta.url);
const fonts = new Map();
const fetchFile = (name) => {
  if (!fonts.has(name)) {
    fonts.set(name, fetch(new URL(name, site)).then((r) => {
      if (!r.ok) throw new Error(`${name}: ${r.status}`);
      return r.arrayBuffer();
    }));
  }
  return fonts.get(name);
};

// The elements and the attributes of an SVG image of ztcl::typeset that
// the page shows. Each other element goes away, and so does each event
// handler and link, so the image runs no script.
const SVG_TAGS = new Set(["svg", "g", "text", "tspan", "rect", "line", "polyline", "polygon", "path", "circle", "ellipse", "title", "desc"]);
function cleanSvg(text) {
  const doc = new DOMParser().parseFromString(text, "image/svg+xml");
  const root = doc.documentElement;
  if (root.localName !== "svg" || doc.querySelector("parsererror")) return null;
  const walk = (el) => {
    for (const c of [...el.children]) {
      if (!SVG_TAGS.has(c.localName)) { c.remove(); continue; }
      walk(c);
    }
    for (const a of [...el.attributes]) {
      const n = a.name.toLowerCase();
      if (n.startsWith("on") || n.endsWith("href") || n === "style" && /url\(|expression/i.test(a.value)) el.removeAttribute(a.name);
    }
  };
  walk(root);
  return document.importNode(root, true);
}

// The trace of the terminal view, and the script that gives the cells:
// one line for each row, cells split by \x1e, fields by \x1f.
const TERM_TRACE = String.raw`package require ztcl::vt
namespace eval ::__term { variable last {} snap {} }
proc ::__term::cells {t} {
    set out {}
    foreach row [ztcl::vt cells $t] {
        set r {}
        foreach c $row { lappend r [join $c \x1f] }
        lappend out [join $r \x1e]
    }
    join $out \n
}
proc ::__term::enter {cmd op} { if {[lindex $cmd 1] eq "delete"} { catch {set ::__term::snap [::__term::cells [lindex $cmd 2]]} } }
proc ::__term::leave {cmd code result op} { if {$code == 0 && [lindex $cmd 1] eq "new"} { set ::__term::last $result; set ::__term::snap {} } }
trace add execution ::ztcl::vt enter ::__term::enter
trace add execution ::ztcl::vt leave ::__term::leave`;
const TERM_CELLS = String.raw`if {$::__term::snap ne ""} { set ::__term::snap } elseif {$::__term::last eq "" || [catch {::__term::cells $::__term::last} v]} { list } else { set v }`;

// The 256 colors of a terminal: the 16 colors from the tokens of
// site.css, then the cube and the grays.
function palette() {
  const css = getComputedStyle(document.documentElement);
  const v = (n) => css.getPropertyValue(n).trim();
  const base = [v("--text"), v("--tok-num"), v("--tok-str"), v("--tok-var"), v("--accent"), v("--tok-kw"), v("--accent-strong"), v("--text-2")];
  const p = [...base, ...base];
  const step = [0, 95, 135, 175, 215, 255];
  for (let i = 16; i < 232; i++) {
    const k = i - 16;
    p.push(`rgb(${step[Math.floor(k / 36)]},${step[Math.floor(k / 6) % 6]},${step[k % 6]})`);
  }
  for (let i = 0; i < 24; i++) p.push(`rgb(${8 + i * 10},${8 + i * 10},${8 + i * 10})`);
  return p;
}

// Renders the cells into the <pre> of the screen: one span for each cell
// with a color or an attribute.
function renderScreen(pre, text) {
  pre.replaceChildren();
  if (!text) { pre.textContent = "The example has no terminal."; return; }
  const pal = palette();
  const color = (c) => (c === "" ? null : c.startsWith("#") ? c : pal[Number(c)]);
  for (const line of text.split("\n")) {
    for (const cell of line.split("\x1e")) {
      const [ch, width, fg, bg, attrs = ""] = cell.split("\x1f");
      if (width === "0") continue;
      const a = attrs.split(" ");
      let f = color(fg), b = color(bg);
      if (a.includes("inverse")) [f, b] = [b ?? "var(--surface)", f ?? "var(--text)"];
      const t = a.includes("hidden") ? " " : ch || " ";
      if (!f && !b && attrs === "") { pre.append(t); continue; }
      const s = document.createElement("span");
      s.textContent = t;
      if (f) s.style.color = f;
      if (b) s.style.background = b;
      if (a.includes("bold")) s.style.fontWeight = "bold";
      if (a.includes("dim")) s.style.opacity = "0.6";
      if (a.includes("italic")) s.style.fontStyle = "italic";
      const deco = [a.includes("underline") && "underline", a.includes("strike") && "line-through"].filter(Boolean).join(" ");
      if (deco) s.style.textDecoration = deco;
      pre.append(s);
    }
    pre.append("\n");
  }
}

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
    if (fig.dataset.wasm) {
      this.files = document.createElement("div");
      this.files.className = "ld-files";
      this.files.hidden = true;
      this.out.after(this.files);
      this.urls = [];
    }
    this.stage = fig.dataset.dom ? fig.querySelector(".ld-stage") : null;
    if (this.stage) this.stageHtml = this.stage.innerHTML;
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
    if (this.stage) this.stop.hidden = true;
    button("Reset", () => { this.ta.value = this.original; this.paint(); this.run(); });
    if (fig.dataset.term) {
      this.screen = document.createElement("pre");
      this.screen.className = "ld-term";
      this.screen.hidden = true;
      this.screen.setAttribute("aria-label", "The screen of the terminal");
      this.out.after(this.screen);
      const show = button("Screen", () => {
        this.screen.hidden = !this.screen.hidden;
        show.setAttribute("aria-expanded", String(!this.screen.hidden));
        if (!this.screen.hidden) this.run();
      });
      show.setAttribute("aria-expanded", "false");
    }
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
    if (this.stage) return this.runDom(m, seq);
    this.tcl?.stop();
    const wasm = this.fig.dataset.wasm || "ztcl.wasm";
    let files = null;
    if (this.fig.dataset.wasm) {
      try {
        const names = (this.fig.dataset.files || "").split(" ").filter(Boolean);
        files = Object.fromEntries(await Promise.all(names.map(async (n) => [n, await fetchFile(n)])));
      } catch (e) {
        this.fig.dataset.live = "failed";
        this.out.textContent = `The fonts did not load: ${e.message}`;
        return;
      }
    }
    const opts = files ? { computeLimit: LIMIT, allow: ["file"], files } : { computeLimit: LIMIT };
    const tcl = (this.tcl = new m.WorkerInterp(new URL(wasm, base), opts));
    let text = "";
    tcl.onOutput = (t) => { text += t; };
    this.stop.disabled = false;
    const term = this.screen && !this.screen.hidden;
    if (term) await tcl.eval(TERM_TRACE);
    const t0 = performance.now();
    const r = await tcl.eval(this.ta.value, { collect: !!files });
    const ms = performance.now() - t0;
    const cells = term ? await tcl.eval(TERM_CELLS) : null;
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
    if (cells && seq === this.seq) renderScreen(this.screen, cells.ok ? cells.result : "");
    if (this.files) this.showFiles(r.files ?? {});
    this.info.textContent = `${ms.toFixed(1)} ms in a worker · compute limit ${LIMIT.toLocaleString("en-US")}`;
    return r;
  }

  // Shows the SVG and PDF files of a run under its output.
  showFiles(files) {
    for (const u of this.urls) URL.revokeObjectURL(u);
    this.urls = [];
    this.files.replaceChildren();
    const names = Object.keys(files).filter((n) => /\.(svg|pdf)$/i.test(n)).sort();
    for (const name of names) {
      const bytes = files[name];
      const box = document.createElement("figure");
      box.className = "ld-file";
      const cap = document.createElement("figcaption");
      cap.textContent = `${name} · ${bytes.length.toLocaleString("en-US")} bytes`;
      if (/\.svg$/i.test(name)) {
        const svg = cleanSvg(new TextDecoder().decode(bytes));
        if (!svg) continue;
        const view = document.createElement("div");
        view.className = "ld-svg";
        view.appendChild(svg);
        box.append(view, cap);
      } else {
        const url = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" }));
        this.urls.push(url);
        const open = document.createElement("a");
        open.href = url;
        open.target = "_blank";
        open.rel = "noopener";
        open.textContent = "Open";
        const save = document.createElement("a");
        save.href = url;
        save.download = name.split("/").pop();
        save.textContent = "Download";
        cap.append(open, save);
        const view = document.createElement("iframe");
        view.src = url;
        view.title = `The PDF ${name}`;
        box.append(view, cap);
      }
      this.files.appendChild(box);
    }
    this.files.hidden = !this.files.children.length;
    this.fig.dataset.outFiles = names.join(" ");
  }

  // Shows the output and the result of a run, or of a run of events.
  show(r, keep) {
    if (!keep) this.out.replaceChildren();
    if (r.output) this.out.append(r.output.endsWith("\n") ? r.output : r.output + "\n");
    if (!r.ok || (!keep && r.result !== "")) {
      const res = document.createElement("span");
      res.className = r.ok ? "ld-result" : "ld-error";
      res.textContent = r.ok ? `=> ${r.result}\n` : `error: ${r.result}\n`;
      this.out.append(res);
    }
  }

  async runDom(m, seq) {
    this.host?.close();
    this.host = null;
    this.stage.innerHTML = this.stageHtml;
    let tcl;
    try {
      tcl = await m.Interp.create(new URL("ztcl-host.wasm", base), {
        allow: ["dom", "event"],
        domRoot: this.stage,
        computeLimit: LIMIT,
        onEvents: (r) => { if (this.host === tcl) this.show(r, true); },
      });
    } catch (e) {
      this.fig.dataset.live = "failed";
      this.out.textContent = `The interpreter did not load: ${e.message}`;
      return;
    }
    if (seq !== this.seq) { tcl.close(); return; }
    this.host = tcl;
    const t0 = performance.now();
    const r = tcl.eval(this.ta.value);
    const ms = performance.now() - t0;
    this.fig.dataset.live = "1";
    this.fig.dataset.ok = String(r.ok);
    this.show(r, false);
    this.info.textContent = `${ms.toFixed(1)} ms in the page · compute limit ${LIMIT.toLocaleString("en-US")}`;
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
      const made = e.fig.dataset.outFiles ? `:files=${e.fig.dataset.outFiles}` : "";
      out.live.push(`${e.fig.id}:${e.fig.dataset.live}:${r?.ok}:${e.out.textContent.slice(0, 40)}${made}`);
    }
    const e = examples[0];
    if (e) {
      e.ta.value = "puts [expr {6 * 7}]";
      await e.run();
      out.checks.edit = e.out.textContent.trim();
      e.ta.value = "while 1 {}";
      const r = await e.run();
      out.checks.limit = r.ok ? "no" : "yes";
      // The example gets its own code again, so the page shows its output.
      e.ta.value = e.original;
      await e.run();
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
