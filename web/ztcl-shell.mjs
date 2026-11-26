// The shell of the runner in a page: the line editor of ztcl on a
// terminal of ztcl::vt, both in ztcl-shell.wasm (src/wasm_shell.zig).
// `zig build wasm-shell` builds that file.
//
// keyBytes() turns a KeyboardEvent into the bytes that a terminal
// sends. feed() gives them to the shell. cells() gives the screen as
// rows of { ch, width, attrs, fg, bg }, and the page renders them. The
// shell has no capability of ztcl. files() gives it read-only files for
// `source`, `open`, and `glob`, so Tab completes their names.
//
// SPDX-License-Identifier: BSD-2-Clause

import { Interp, compile } from "./ztcl.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// The bytes of the keys with no text, as xterm sends them.
const SPECIAL = {
  Enter: "\r", Backspace: "\x7f", Tab: "\t", Escape: "\x1b",
  ArrowUp: "\x1b[A", ArrowDown: "\x1b[B", ArrowRight: "\x1b[C", ArrowLeft: "\x1b[D",
  Home: "\x1b[H", End: "\x1b[F", Delete: "\x1b[3~", Insert: "\x1b[2~",
  PageUp: "\x1b[5~", PageDown: "\x1b[6~",
};

/// The bytes of a key, or null for a key that the page keeps (Cmd on
/// macOS, function keys, and the modifier keys alone).
export function keyBytes(e) {
  if (e.metaKey || e.isComposing) return null;
  if (e.key === "Tab" && e.shiftKey) return "\x1b[Z";
  if (e.key in SPECIAL) {
    const s = SPECIAL[e.key];
    return e.altKey && s.length === 1 ? "\x1b" + s : s;
  }
  if (e.key.length !== 1 && [...e.key].length !== 1) return null;
  if (e.ctrlKey && !e.altKey) {
    const c = e.key.toLowerCase().charCodeAt(0);
    if (c >= 97 && c <= 122) return String.fromCharCode(c - 96);
    const map = { " ": "\x00", "@": "\x00", "[": "\x1b", "\\": "\x1c", "]": "\x1d", "/": "\x1f", "_": "\x1f" };
    return map[e.key] ?? null;
  }
  return e.altKey ? "\x1b" + e.key : e.key;
}

/// The files of a bundle payload (src/wasmbundle.zig): "ZTB1", the
/// count, then for each file its kind, name length, data length, name,
/// and data. `files` is an object of name to text.
export function bundle(files) {
  const parts = Object.entries(files).map(([n, d]) => [encoder.encode(n), encoder.encode(d)]);
  const size = 8 + parts.reduce((s, [n, d]) => s + 9 + n.length + d.length, 0);
  const out = new Uint8Array(size);
  const view = new DataView(out.buffer);
  out.set(encoder.encode("ZTB1"), 0);
  view.setUint32(4, parts.length, true);
  let at = 8;
  for (const [n, d] of parts) {
    out[at] = 1;
    view.setUint32(at + 1, n.length, true);
    view.setUint32(at + 5, d.length, true);
    out.set(n, at + 9);
    out.set(d, at + 9 + n.length);
    at += 9 + n.length + d.length;
  }
  return out;
}

/// The URL of the ztcl-shell.wasm file next to this file.
export function shellURL() {
  return new URL("./ztcl-shell.wasm", import.meta.url);
}

export class Shell {
  /// Makes a shell in a new instance of `module` (as for compile(); the
  /// default is ztcl-shell.wasm next to this file).
  /// Options: cols, rows, computeLimit (compute units for each command),
  /// memLimit (bytes), files (an object of name to text).
  static async create(module, options = {}) {
    if (module != null && Object.getPrototypeOf(module) === Object.prototype) [module, options] = [undefined, module];
    const it = await Interp.create(await compile(module ?? shellURL()), { memLimit: options.memLimit ?? 64 << 20 });
    return new Shell(it, options);
  }

  constructor(it, { cols = 80, rows = 24, computeLimit = 10_000_000, files = null } = {}) {
    this.it = it;
    this.x = it.x;
    if (!this.x.ztcl_shell_new) throw new Error("the module has no shell: use ztcl-shell.wasm");
    this.computeLimit = computeLimit;
    this.cols = cols;
    this.rows = rows;
    this.s = this.x.ztcl_shell_new(it.h, cols, rows, BigInt(computeLimit));
    if (!this.s) throw new Error("ztcl_shell_new: out of memory");
    if (files) {
      const bytes = bundle(files);
      const ptr = this._copy(bytes);
      if (this.x.ztcl_shell_files(this.s, ptr, bytes.length) !== 0) throw new Error("ztcl_shell_files: out of memory");
    }
  }

  _copy(bytes) {
    const ptr = this.x.ztcl_alloc(bytes.length || 1);
    if (!ptr) throw new Error("ztcl_alloc: out of memory");
    new Uint8Array(this.x.memory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  }

  _with(text, f) {
    const bytes = typeof text === "string" ? encoder.encode(text) : text;
    const ptr = this._copy(bytes);
    try {
      return f(ptr, bytes.length);
    } finally {
      this.x.ztcl_free(ptr, bytes.length || 1);
    }
  }

  /// Gives key bytes (a string or bytes) to the shell.
  feed(bytes) {
    const rc = this._with(bytes, (p, n) => this.x.ztcl_shell_feed(this.s, p, n, 1));
    if (rc !== 0) throw new Error("ztcl_shell_feed: out of memory");
  }

  /// Gives pasted text to the shell, in the brackets of a paste.
  paste(text) {
    this.feed("\x1b[200~" + text.replace(/\r\n?/g, "\n") + "\x1b[201~");
  }

  /// Writes text above the prompt.
  print(text) {
    this._with(text, (p, n) => this.x.ztcl_shell_print(this.s, p, n));
  }

  resize(cols, rows) {
    if (cols === this.cols && rows === this.rows) return;
    this.cols = cols;
    this.rows = rows;
    this.x.ztcl_shell_resize(this.s, cols, rows);
  }

  set vi(on) {
    this.x.ztcl_shell_set_vi(this.s, on ? 1 : 0);
  }

  /// The count of scrollback lines above the screen.
  get scrollback() {
    return this.x.ztcl_shell_scrollback(this.s);
  }

  /// The compute units of the last command.
  get lastCompute() {
    return Number(this.x.ztcl_shell_last_compute(this.s));
  }

  /// The cursor: { x, y, style, visible }. style is the DECSCUSR number.
  get cursor() {
    const c = this.x.ztcl_shell_cursor(this.s);
    return { x: c & 0xffff, y: (c >>> 16) & 0xff, style: (c >>> 24) & 15, visible: (c >>> 28) & 1 };
  }

  /// The text of the line when the editor key asks for an editor, or
  /// null. setLine() gives the edited text back.
  get editorText() {
    if (!this.x.ztcl_shell_editor(this.s)) return null;
    const p = this.x.ztcl_shell_line_ptr(this.s);
    return decoder.decode(new Uint8Array(this.x.memory.buffer, p, this.x.ztcl_shell_line_len(this.s)));
  }

  setLine(text) {
    this._with(text, (p, n) => this.x.ztcl_shell_set_line(this.s, p, n));
  }

  /// The cells of the screen, `up` lines above the bottom: rows of
  /// { ch, width, attrs, fg, bg }. A color is null, { index }, or { rgb }.
  cells(up = 0) {
    const p = this.x.ztcl_shell_cells(this.s, up);
    if (!p) throw new Error("ztcl_shell_cells: out of memory");
    const w = new Uint32Array(this.x.memory.buffer, p, this.cols * this.rows * 3);
    const color = (v) => (v === 0 ? null : v < 0x2000000 ? { index: v & 0xff } : { rgb: v & 0xffffff });
    const rows = [];
    for (let y = 0; y < this.rows; y++) {
      const row = [];
      for (let x = 0; x < this.cols; x++) {
        const at = (y * this.cols + x) * 3;
        const a = w[at];
        const cp = a & 0x1fffff;
        row.push({ ch: cp ? String.fromCodePoint(cp) : " ", width: (a >>> 21) & 3, attrs: (a >>> 23) & 0xff, fg: color(w[at + 1]), bg: color(w[at + 2]) });
      }
      rows.push(row);
    }
    return rows;
  }

  /// The text of each row of the screen, with the trailing blanks removed.
  text(up = 0) {
    return this.cells(up).map((r) => r.filter((c) => c.width !== 0).map((c) => c.ch).join("").trimEnd());
  }

  close() {
    this.it.close?.();
  }
}

/// The bits of `attrs` in a cell.
export const ATTR = { bold: 1, dim: 2, italic: 4, underline: 8, blink: 16, inverse: 32, hidden: 64, strike: 128 };
