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
    const cols = this.colsFor(this.poster.clientWidth);
    this.shell = await this.mod.Shell.create({ cols, rows: this.rows, computeLimit: LIMIT, files: FILES });
    this.shell.print(el.dataset.banner.replaceAll("\\n", "\n") + "\n");

    const box = document.createElement("div");
    box.className = "zshell-screen";
    box.style.height = this.poster.offsetHeight + "px";
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
    this.fit();
  }

  colsFor(width) {
    return Math.max(20, Math.floor((width - 2 * this.pad) / this.cellW));
  }

  fit() {
    this.shell.resize(this.colsFor(this.box.clientWidth), this.rows);
    this.render();
  }

  // The keys with no text go here. The text of a key goes to typed().
  key(e) {
    if (e.key === "Tab" && !e.shiftKey && performance.now() - this.escAt < 1000) return;
    if (e.key === "Escape") this.escAt = performance.now();
    if (e.key === "c" && e.ctrlKey && e.shiftKey) return;
    const b = this.mod.keyBytes(e);
    if (b == null) return;
    e.preventDefault();
    this.send(() => this.shell.feed(b), b === "\r");
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

function mount(el) {
  const go = async () => {
    try {
      await new View(el, await load()).start();
    } catch (err) {
      const hint = el.querySelector(".zshell-hint");
      if (hint) hint.textContent = `The shell did not start: ${err.message}`;
    }
  };
  const seen = new IntersectionObserver((entries) => {
    if (entries.some((e) => e.isIntersecting)) {
      seen.disconnect();
      go();
    }
  });
  seen.observe(el);
}

if (typeof WebAssembly === "object") document.querySelectorAll(".zshell").forEach(mount);
