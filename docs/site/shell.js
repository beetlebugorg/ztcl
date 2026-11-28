// The shell in the page: web/ztcl-shell.mjs on a canvas.
//
// Each element with the class "zshell" has a poster: a <pre> with the
// first screen of the shell as text. The page works with no JavaScript,
// and the poster shows. When the element comes into view, this module
// loads ztcl-shell.wasm and puts a canvas of the same size in place of
// the poster. The page does not type into the shell. The shell runs
// only on keys of the reader.
//
// A textarea over the canvas gets the keys, so the keyboard and a
// screen reader reach the shell. The text that a command prints goes to
// a live region. Escape and then Tab within one second moves the focus
// out of the shell; each other Tab goes to the shell for completion.
// The canvas renders again only after a key, a paste, a scroll, a resize,
// or a change of the color scheme. Nothing runs between those events.
//
// SPDX-License-Identifier: BSD-2-Clause

const LIMIT = 10_000_000;
const FILES = {
  "README.txt": "These files are read-only and live in this page.\nTry: source examples/fib.tcl\n",
  "examples/fib.tcl": "proc fib {n} {\n    expr {$n < 2 ? $n : [fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]}\n}\nputs \"fib 20 = [fib 20]\"\n",
  "examples/primes.tcl": "set primes {}\nfor {set n 2} {[llength $primes] < 10} {incr n} {\n    set p 1\n    foreach q $primes { if {$n % $q == 0} { set p 0; break } }\n    if {$p} { lappend primes $n }\n}\nputs $primes\n",
  "examples/dict.tcl": "set user [dict create name Ada lang Tcl]\ndict for {k v} $user { puts \"$k: $v\" }\n",
};
const fmt = (n) => n.toLocaleString("en-US");

// The 16 colors of ANSI from the tokens of site.css, then the cube and
// the grays of the 256-color palette.
function palette(el) {
  const css = getComputedStyle(el);
  const v = (n) => css.getPropertyValue(n).trim();
  const base = [v("--text"), v("--tok-num"), v("--tok-str"), v("--tok-var"), v("--accent"), v("--tok-kw"), v("--accent-strong"), v("--text-2")];
  const p = [...base, ...base];
  const step = [0, 95, 135, 175, 215, 255];
  for (let i = 16; i < 232; i++) {
    const k = i - 16;
    p.push(`rgb(${step[Math.floor(k / 36)]},${step[Math.floor(k / 6) % 6]},${step[k % 6]})`);
  }
  for (let i = 0; i < 24; i++) p.push(`rgb(${8 + i * 10},${8 + i * 10},${8 + i * 10})`);
  return { p, fg: v("--text"), bg: v("--surface"), cursor: v("--accent") };
}

function cssColor(c, pal, dflt) {
  if (!c) return dflt;
  if (c.index !== undefined) return pal.p[c.index];
  return "#" + c.rgb.toString(16).padStart(6, "0");
}

class View {
  constructor(el, mod) {
    this.el = el;
    this.mod = mod;
    this.poster = el.querySelector("pre.zshell-poster");
    this.rows = Number(el.dataset.rows || 14);
    this.up = 0;
    this.focused = false;
    this.escAt = -Infinity;
  }

  async start() {
    const el = this.el;
    const css = getComputedStyle(this.poster);
    this.font = `${css.fontSize} ${css.fontFamily}`;
    this.lineH = parseFloat(css.lineHeight) || parseFloat(css.fontSize) * 1.5;
    this.pad = parseFloat(css.paddingLeft) || 0;
    const probe = document.createElement("canvas").getContext("2d");
    probe.font = this.font;
    this.cellW = probe.measureText("MMMMMMMMMM").width / 10;
    // A course shell can start in a closed dock (for a helper), with no
    // size: it then starts at 60 columns, and fit() sets its size when
    // the dock opens.
    this.cols0 = this.poster.clientWidth ? this.colsFor(this.poster.clientWidth) : 60;
    // A shell of the Learn course (class zcourse) fills its panel. It
    // keeps the commands of the reader for its lesson in sessionStorage.
    this.course = el.dataset.lesson ? `ztcl-learn:${el.dataset.lesson}` : null;
    if (this.course && this.poster.clientHeight) this.rows = Math.max(4, Math.floor((this.poster.clientHeight - 20) / this.lineH));
    await this.boot(true);

    const box = document.createElement("div");
    box.className = "zshell-screen";
    if (!this.course) box.style.height = this.poster.offsetHeight + "px";
    this.canvas = document.createElement("canvas");
    this.canvas.setAttribute("aria-hidden", "true");
    this.input = document.createElement("textarea");
    this.input.className = "zshell-input";
    this.input.setAttribute("aria-label", el.dataset.label || "ztcl shell");
    this.input.setAttribute("aria-describedby", el.querySelector(".zshell-hint")?.id || "");
    for (const [k, v] of Object.entries({ autocapitalize: "off", autocomplete: "off", autocorrect: "off", spellcheck: "false" })) this.input.setAttribute(k, v);
    this.live = document.createElement("div");
    this.live.className = "sr-only";
    this.live.setAttribute("aria-live", "polite");
    box.append(this.canvas, this.input, this.live);
    this.poster.replaceWith(box);
    this.box = box;

    this.input.addEventListener("keydown", (e) => this.key(e));
    this.input.addEventListener("input", () => this.typed());
    this.input.addEventListener("paste", (e) => {
      e.preventDefault();
      this.send(() => this.shell.paste(e.clipboardData.getData("text")));
    });
    this.input.addEventListener("focus", () => { this.focused = true; this.render(); });
    this.input.addEventListener("blur", () => { this.focused = false; this.render(); });
    box.addEventListener("mousedown", (e) => { e.preventDefault(); this.input.focus(); });
    box.addEventListener("wheel", (e) => this.wheel(e), { passive: false });
    new ResizeObserver(() => this.fit()).observe(box);
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => this.render());
    const vi = el.querySelector("input.zshell-vi");
    if (vi) {
      vi.disabled = false;
      vi.addEventListener("change", () => { this.shell.vi = vi.checked; this.render(); this.input.focus(); });
    }
    this.meter = el.querySelector(".zshell-meter");
    // The dock button keeps the shell in a corner of the window while
    // the reader scrolls, and puts it back in the page.
    this.docked = false;
    this.dockBtn = el.querySelector(".zshell-dock");
    if (this.dockBtn) {
      this.dockBtn.hidden = false;
      this.dockBtn.addEventListener("click", () => { this.dock(!this.docked); this.input.focus({ preventScroll: true }); });
    }
    if (this.course) el.querySelector(".zcourse-again")?.addEventListener("click", () => this.again());
    this.fit();
  }

  // A new interpreter with the state of the page. A course shell then
  // runs the saved commands of the reader for this lesson again.
  async boot(replay) {
    const el = this.el;
    const state = el.querySelector("script.zpage-state");
    const page = state ? JSON.parse(state.textContent) : null;
    const cols = this.shell ? this.shell.cols : this.cols0;
    this.shell?.close();
    this.shell = await this.mod.Shell.create({ cols, rows: this.rows, computeLimit: LIMIT, files: page ? page.files : FILES });
    // The state of a docs page runs first, with the same compute limit.
    this.shell.it.computeLimit = LIMIT;
    if (page?.setup) {
      const r = this.shell.it.eval(page.setup);
      if (!r.ok) this.shell.print(`The state of the page did not load: ${r.result}\n`);
    }
    this.shell.print(el.dataset.banner.replaceAll("\\n", "\n") + "\n");
    const saved = replay ? this.saved() : [];
    for (const cmd of saved) this.shell.it.eval(cmd);
    if (saved.length) this.shell.print(`Ran your ${saved.length} earlier ${saved.length === 1 ? "command" : "commands"} of this lesson again. Start again clears them.\n`);
  }

  saved() {
    try {
      return JSON.parse(sessionStorage.getItem(this.course) || "[]");
    } catch {
      return [];
    }
  }

  // A command of the reader goes to the list of the lesson.
  keep(cmd) {
    if (!this.course || !cmd.trim()) return;
    try {
      const list = this.saved();
      list.push(cmd);
      sessionStorage.setItem(this.course, JSON.stringify(list.slice(-200)));
    } catch {
      // No storage: the commands go away with the page.
    }
  }

  async again() {
    try {
      sessionStorage.removeItem(this.course);
    } catch {
      // No storage.
    }
    await this.boot(false);
    this.up = 0;
    this.render();
    this.input.focus({ preventScroll: true });
  }

  // A Run link: the command goes on the line and runs, as if the reader
  // typed it and pressed Enter. The page does not scroll.
  runLine(cmd) {
    if (this.course) courseDock?.show(true);
    this.shell.setLine(cmd);
    this.keep(cmd);
    this.send(() => this.shell.feed("\r"), true);
    this.input.focus({ preventScroll: true });
  }

  // A docked shell is fixed in the window. An empty box of the same size
  // keeps its place in the page, so that the text does not move.
  dock(on) {
    if (on === this.docked) return;
    this.docked = on;
    if (on) {
      const r = this.el.getBoundingClientRect();
      const css = getComputedStyle(this.el);
      this.hold = document.createElement("div");
      this.hold.style.height = `${r.height}px`;
      this.hold.style.margin = `${css.marginTop} 0 ${css.marginBottom}`;
      this.el.before(this.hold);
      this.el.style.setProperty("--dock-w", `${r.width}px`);
      this.el.classList.add("zshell-docked");
    } else {
      this.hold?.remove();
      this.hold = null;
      this.el.classList.remove("zshell-docked");
    }
    if (this.dockBtn) {
      this.dockBtn.textContent = on ? "Put back" : "Keep in view";
      this.dockBtn.setAttribute("aria-pressed", String(on));
    }
  }

  // True when the screen of the shell is all in the window.
  inView() {
    const r = this.box.getBoundingClientRect();
    return r.top >= 0 && r.bottom <= innerHeight;
  }

  // A helper puts a command on the line. The reader runs it with Enter.
  // The page keeps its scroll position.
  put(text) {
    this.shell.setLine(text);
    this.up = 0;
    // The page does not scroll: a shell out of view docks in the window,
    // and a course shell opens its dock.
    if (this.course) courseDock?.show(true);
    else if (!this.inView()) this.dock(true);
    this.render();
    this.input.focus({ preventScroll: true });
  }

  // A helper runs a command in the interpreter of the shell, with the
  // compute limit, and gets { ok, result }. The screen does not change.
  // A `limit` from 1 to the limit of the shell is the compute limit of
  // this one call.
  run(script, limit) {
    const it = this.shell.it;
    const saved = it.computeLimit;
    if (Number.isInteger(limit) && limit > 0) it.computeLimit = Math.min(limit, LIMIT);
    try {
      const r = it.eval(script);
      return { ok: r.ok, result: r.result };
    } finally {
      it.computeLimit = saved;
    }
  }

  colsFor(width) {
    return Math.max(20, Math.floor((width - 2 * this.pad) / this.cellW));
  }

  fit() {
    if (!this.box.clientWidth) return;
    if (this.course) this.rows = Math.max(4, Math.floor(this.box.clientHeight / this.lineH));
    this.shell.resize(this.colsFor(this.box.clientWidth), this.rows);
    this.render();
  }

  // The keys with no text go here. The text of a key goes to typed().
  key(e) {
    if (e.altKey && e.code === "KeyI" && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      this.inspect();
      return;
    }
    if (e.key === "Tab" && !e.shiftKey && performance.now() - this.escAt < 1000) return;
    if (e.key === "Escape") this.escAt = performance.now();
    if (e.key === "c" && e.ctrlKey && e.shiftKey) return;
    const b = this.mod.keyBytes(e);
    if (b == null) return;
    e.preventDefault();
    const line = b === "\r" && this.course ? this.shell.line : null;
    this.send(() => this.shell.feed(b), b === "\r");
    // The line is empty after Enter when the command ran. A line that
    // goes on (an open brace) stays.
    if (line && this.shell.line === "") this.keep(line);
  }

  // Text from a virtual keyboard or an input method.
  typed() {
    const t = this.input.value;
    this.input.value = "";
    if (t) this.send(() => this.shell.feed(t.replace(/\n/g, "\r")), t.includes("\n"));
  }

  send(f, enter = false) {
    const before = this.shell.scrollback + this.shell.cursor.y;
    f();
    this.up = 0;
    if (enter) this.after(before);
    const t = this.shell.editorText;
    if (t !== null) this.edit(t);
    this.render();
  }

  // After a command: the meter, and the printed rows for a screen reader.
  after(before) {
    const used = this.shell.lastCompute;
    if (this.meter) {
      this.meter.querySelector("span").textContent = `Last command: ${fmt(used)} of ${fmt(LIMIT)} compute units`;
      const bar = this.meter.querySelector("progress");
      bar.value = used;
      bar.max = LIMIT;
    }
    // A row is a count from the top of the scrollback. The last 20 rows
    // above the new prompt go to the live region.
    const sb = this.shell.scrollback;
    const now = sb + this.shell.cursor.y;
    const lines = [];
    for (let row = Math.max(before + 1, now - 20); row < now; row++) {
      const up = Math.max(0, sb - row);
      lines.push(this.shell.text(up)[row - (sb - up)]);
    }
    this.live.textContent = lines.join("\n") || "(no output)";
  }

  wheel(e) {
    const max = this.shell.scrollback;
    if (!max) return;
    e.preventDefault();
    this.up = Math.max(0, Math.min(max, this.up + (e.deltaY < 0 ? 3 : -3)));
    this.render();
  }

  // The editor key: a dialog with the text of the line.
  edit(text) {
    const d = document.createElement("dialog");
    d.className = "zshell-editor";
    d.innerHTML = `<form method="dialog"><label>Edit the command<textarea rows="10" spellcheck="false"></textarea></label>
<div class="btns"><button value="ok" class="btn primary">Put in the line</button><button value="cancel" class="btn ghost">Cancel</button></div></form>`;
    const ta = d.querySelector("textarea");
    ta.value = text;
    ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); d.close("ok"); } });
    d.addEventListener("close", () => {
      this.shell.setLine(d.returnValue === "ok" ? ta.value : text);
      d.remove();
      this.render();
      this.input.focus();
    });
    document.body.append(d);
    d.showModal();
    ta.focus();
  }

  // Alt-I: a dialog with the last result as a tree. The page sets the
  // variable _ to the result, so that the path of each node runs.
  inspect() {
    const v = this.shell.lastResult;
    const d = document.createElement("dialog");
    d.className = "zshell-editor zshell-inspect";
    d.innerHTML = `<form method="dialog"><h2>The last result</h2><p class="note"></p><div class="tree"></div>
<div class="btns"><button value="cancel" class="btn ghost">Close</button></div></form>`;
    const note = d.querySelector(".note");
    if (v === null) note.textContent = "No command gave a result yet. Run a command, then press Alt-I.";
    else {
      this.shell.it.eval("set ::_ " + tclQuote(v));
      note.textContent = "The variable _ has the result. A button puts the path of its node on the line of the shell.";
      d.querySelector(".tree").append(inspectNode("_", v, "$_", [], 0, (path) => {
        this.shell.setLine(path);
        d.close();
      }));
    }
    d.addEventListener("close", () => {
      d.remove();
      this.render();
      this.input.focus();
    });
    document.body.append(d);
    d.showModal();
    (d.querySelector(".tree summary, .tree button") || d.querySelector("button")).focus();
  }

  render() {
    const s = this.shell;
    const pal = palette(this.el);
    const dpr = window.devicePixelRatio || 1;
    const w = this.box.clientWidth;
    const h = this.box.clientHeight;
    const c = this.canvas;
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
      c.width = Math.round(w * dpr);
      c.height = Math.round(h * dpr);
      c.style.width = w + "px";
      c.style.height = h + "px";
    }
    const g = c.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.fillStyle = pal.bg;
    g.fillRect(0, 0, w, h);
    g.textBaseline = "middle";
    const top = (h - this.rows * this.lineH) / 2;
    const rows = s.cells(this.up);
    const cur = s.cursor;
    for (let y = 0; y < rows.length; y++) {
      const py = top + y * this.lineH;
      for (let x = 0; x < rows[y].length; x++) {
        const cell = rows[y][x];
        if (cell.width === 0) continue;
        const px = this.pad + x * this.cellW;
        let fg = cssColor(cell.fg, pal, pal.fg);
        let bg = cell.bg ? cssColor(cell.bg, pal, pal.bg) : null;
        if (cell.attrs & 32) [fg, bg] = [bg ?? pal.bg, fg];
        const cw = this.cellW * (cell.width || 1);
        if (bg) {
          g.fillStyle = bg;
          g.fillRect(px, py, cw, this.lineH);
        }
        const atCursor = this.up === 0 && cur.visible && x === cur.x && y === cur.y;
        if (atCursor && this.focused && cur.style <= 2) {
          g.fillStyle = pal.cursor;
          g.fillRect(px, py, cw, this.lineH);
          fg = pal.bg;
        }
        if (cell.ch !== " " && !(cell.attrs & 64)) {
          g.font = `${cell.attrs & 4 ? "italic " : ""}${cell.attrs & 1 ? "600 " : ""}${this.font}`;
          g.globalAlpha = cell.attrs & 2 ? 0.55 : 1;
          g.fillStyle = fg;
          g.fillText(cell.ch, px, py + this.lineH / 2);
          g.globalAlpha = 1;
        }
        if (cell.attrs & 8) {
          g.fillStyle = fg;
          g.fillRect(px, py + this.lineH - 2, cw, 1);
        }
        if (atCursor && !(this.focused && cur.style <= 2)) {
          g.strokeStyle = g.fillStyle = pal.cursor;
          if (!this.focused) g.strokeRect(px + 0.5, py + 0.5, cw - 1, this.lineH - 1);
          else if (cur.style >= 5) g.fillRect(px, py + 2, 2, this.lineH - 4);
          else g.fillRect(px, py + this.lineH - 3, cw, 2);
        }
      }
    }
  }
}

let mod = null;
async function load() {
  mod ??= import("../playground/ztcl-shell.mjs");
  return mod;
}

// The start of each shell, once: on view, or when a helper asks for it.
const starts = new WeakMap();
function begin(el) {
  if (!starts.has(el)) {
    starts.set(el, (async () => {
      try {
        const view = new View(el, await load());
        await view.start();
        return view;
      } catch (err) {
        const hint = el.querySelector(".zshell-hint");
        if (hint) hint.textContent = `The shell did not start: ${err.message}`;
        throw err;
      }
    })());
  }
  return starts.get(el);
}

function mount(el) {
  const seen = new IntersectionObserver((entries) => {
    if (entries.some((e) => e.isIntersecting)) {
      seen.disconnect();
      begin(el).catch(() => {});
    }
  });
  seen.observe(el);
}

// A Tcl word for any text: a quoted string with the special characters
// escaped.
function tclQuote(s) {
  return '"' + s.replace(/[\\"$[\]]/g, (c) => "\\" + c).replace(/\n/g, "\\n").replace(/\r/g, "\\r") + '"';
}

// A word for a dict key or a list index in a path: bare when it has no
// special characters, else in braces or quotes.
function pathWord(s) {
  if (/^[\w.:-]+$/.test(s)) return s;
  if (!/[{}\\]/.test(s)) return `{${s}}`;
  return tclQuote(s);
}

const SPACE = " \t\n\r\v\f";
const ESC = { n: "\n", t: "\t", r: "\r", f: "\f", v: "\v", a: "\x07", b: "\b" };

/// The words of a Tcl list, or null when the text is not a list. The
/// backslash escapes of one character are the only ones it changes.
export function tclList(s) {
  const out = [];
  let i = 0;
  const n = s.length;
  for (;;) {
    while (i < n && SPACE.includes(s[i])) i++;
    if (i >= n) return out;
    let w = "";
    if (s[i] === "{") {
      let depth = 1;
      const start = ++i;
      while (i < n && depth) {
        if (s[i] === "\\") i++;
        else if (s[i] === "{") depth++;
        else if (s[i] === "}") depth--;
        i++;
      }
      if (depth) return null;
      w = s.slice(start, i - 1);
    } else {
      const quoted = s[i] === '"';
      if (quoted) i++;
      while (i < n && (quoted ? s[i] !== '"' : !SPACE.includes(s[i]))) {
        if (s[i] === "\\" && i + 1 < n) {
          w += ESC[s[i + 1]] ?? s[i + 1];
          i += 2;
        } else w += s[i++];
      }
      if (quoted) {
        if (i >= n) return null;
        i++;
      }
    }
    if (i < n && !SPACE.includes(s[i])) return null;
    out.push(w);
  }
}

// The kind of a value for the inspector: a dict when it is a list of an
// even count with unique keys that are names, a list when it has more
// than one word, else a leaf.
function kindOf(v) {
  const w = tclList(v);
  if (!w || w.length === 0 || (w.length === 1 && w[0] === v)) return { kind: "leaf" };
  if (w.length % 2 === 0) {
    const keys = w.filter((_, i) => i % 2 === 0);
    if (new Set(keys).size === keys.length && keys.every((k) => /^[A-Za-z_][\w.:-]*$/.test(k))) return { kind: "dict", w };
  }
  return { kind: "list", w };
}

const MAX_ROWS = 200;

// One node of the inspector. base is a Tcl word for a value, and keys
// is a path of dict keys in it.
function inspectNode(name, v, base, keys, depth, put) {
  const word = keys.length ? `[dict get ${base} ${keys.map(pathWord).join(" ")}]` : base;
  const path = word === "$_" ? "set _" : word.startsWith("[") ? word.slice(1, -1) : `set ${word.slice(1)}`;
  const k = depth < 8 ? kindOf(v) : { kind: "leaf" };
  const row = document.createElement("div");
  row.className = "row";
  const code = document.createElement("code");
  code.textContent = path;
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "btn ghost";
  btn.textContent = "Put in the shell";
  btn.addEventListener("click", () => put(path));
  row.append(code, btn);
  const label = (text) => {
    const b = document.createElement("b");
    b.textContent = name;
    const span = document.createElement("span");
    span.textContent = text;
    return [b, " ", span];
  };
  if (k.kind === "leaf") {
    const div = document.createElement("div");
    div.className = "leaf";
    div.append(...label(v.length > 80 ? v.slice(0, 80) + " (" + v.length + " characters)" : v || "(empty)"), row);
    return div;
  }
  const det = document.createElement("details");
  det.open = depth === 0;
  const sum = document.createElement("summary");
  const count = k.kind === "dict" ? `dict of ${k.w.length / 2} keys` : `list of ${k.w.length} items`;
  sum.append(...label(count));
  det.append(sum, row);
  const kids = document.createElement("div");
  kids.className = "kids";
  if (k.kind === "dict") {
    for (let i = 0; i < k.w.length && i < 2 * MAX_ROWS; i += 2) kids.append(inspectNode(k.w[i], k.w[i + 1], base, [...keys, k.w[i]], depth + 1, put));
  } else {
    k.w.slice(0, MAX_ROWS).forEach((item, i) => kids.append(inspectNode(String(i), item, `[lindex ${word} ${i}]`, [], depth + 1, put)));
  }
  const total = k.kind === "dict" ? k.w.length / 2 : k.w.length;
  if (total > MAX_ROWS) {
    const more = document.createElement("p");
    more.textContent = `${total - MAX_ROWS} more are not shown.`;
    kids.append(more);
  }
  det.append(kids);
  return det;
}

/// The shell of a docs page (docs/site/helper.js uses it). It starts the
/// shell if it is not started.
export function pageShell() {
  const el = document.querySelector(".zpage-shell");
  return el ? begin(el) : Promise.reject(new Error("this page has no shell"));
}

// localStorage can throw (a private window, blocked site data), and the
// dock then works with no memory.
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* no memory */ } },
};
const NARROW = matchMedia("(max-width: 960px)");
const DOCK_KEY = "ztcl-course-dock";
const SIZE_KEY = "ztcl-course-size";

// The dock of a course shell (site.css): the button Try it, and the
// shell as a panel or a sheet. The class "open" of the dock shows the
// shell. The shell starts when it first shows, since a closed shell is
// not in view. The state open or closed and the size of the panel stay
// in localStorage for the next page. A narrow window opens the sheet
// only on a tap: the stored state does not open it.
function setupDock(dock) {
  const button = dock.querySelector(".zcourse-open");
  const panel = dock.querySelector(".zcourse");
  const close = dock.querySelector(".zcourse-close");
  const grip = dock.querySelector(".zcourse-grip");
  const set = (on, save) => {
    dock.classList.toggle("open", on);
    document.body.classList.toggle("zcourse-on", on);
    button.setAttribute("aria-expanded", String(on));
    if (save) store.set(DOCK_KEY, on ? "open" : "closed");
  };
  const size = (w, h) => {
    panel.style.setProperty("--dock-w", `${Math.round(w)}px`);
    panel.style.setProperty("--dock-h", `${Math.round(h)}px`);
  };
  try {
    const s = JSON.parse(store.get(SIZE_KEY) || "null");
    if (s && s.w > 0 && s.h > 0) size(s.w, s.h);
  } catch { /* a bad stored size: the default size */ }
  button.addEventListener("click", () => {
    set(true, true);
    begin(panel).then((v) => v.input.focus({ preventScroll: true })).catch(() => {});
  });
  close.addEventListener("click", () => {
    set(false, true);
    button.focus({ preventScroll: true });
  });
  // The grip is at the top left corner and the panel is fixed at the
  // bottom right, so a drag up and to the left makes the panel larger.
  grip.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    grip.setPointerCapture(e.pointerId);
    const r = panel.getBoundingClientRect();
    const x0 = e.clientX, y0 = e.clientY;
    const move = (m) => size(Math.max(320, r.width + x0 - m.clientX), Math.max(220, r.height + y0 - m.clientY));
    const up = () => {
      grip.removeEventListener("pointermove", move);
      const b = panel.getBoundingClientRect();
      store.set(SIZE_KEY, JSON.stringify({ w: Math.round(b.width), h: Math.round(b.height) }));
    };
    grip.addEventListener("pointermove", move);
    grip.addEventListener("lostpointercapture", up, { once: true });
  });
  button.hidden = false;
  document.body.classList.add("zcourse-ready");
  if (!NARROW.matches && store.get(DOCK_KEY) === "open") set(true, false);
  return { show: (save) => { if (!dock.classList.contains("open")) set(true, save); } };
}

const dockEl = typeof WebAssembly === "object" ? document.querySelector(".zcourse-dock") : null;
const courseDock = dockEl ? setupDock(dockEl) : null;

if (typeof WebAssembly === "object") {
  document.querySelectorAll(".zshell").forEach(mount);
  // The Run links and the code boxes of a lesson.
  const run = (e) => {
    const b = e.target.closest?.(".zrun, .zrun-box");
    if (!b) return;
    e.preventDefault();
    courseDock?.show(true);
    pageShell().then((v) => v.runLine(b.dataset.cmd)).catch(() => {});
  };
  document.addEventListener("click", run);
  // A Run link is a span with the role of a button: Enter and Space run it.
  document.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.classList?.contains("zrun")) run(e);
  });
}
