// Tests the shell of ztcl-shell.wasm (src/wasm_shell.zig) through
// web/ztcl-shell.mjs: completion of commands, subcommands, variables,
// and file names, the history, the vim keys, the colors, the editor key,
// and the compute limit.
//
//     zig build wasm-shell && node tools/wasm-shell.mjs zig-out/lib/ztcl-shell.wasm
//
// SPDX-License-Identifier: BSD-2-Clause

import { Shell } from "../web/ztcl-shell.mjs";
import { readFileSync } from "node:fs";

const wasm = new WebAssembly.Module(readFileSync(process.argv[2] ?? "zig-out/lib/ztcl-shell.wasm"));
let failed = 0;
let count = 0;

function check(name, ok, detail) {
  count++;
  if (!ok) {
    failed++;
    console.log(`FAIL ${name}\n${detail}`);
  }
}

async function shell(opts = {}) {
  return Shell.create(wasm, { cols: 60, rows: 12, computeLimit: 100_000, ...opts });
}

const screen = (s) => s.text().join("\n");

{
  const s = await shell();
  s.feed("set answer 42\r");
  check("a command prints its result", screen(s).includes("42"), screen(s));
  s.feed("pu\t");
  check("Tab completes a command", s.text()[s.cursor.y] === "% puts" && s.cursor.x === 7, screen(s));
  s.feed("\x15string tou\t");
  check("Tab completes a subcommand", s.text()[s.cursor.y] === "% string toupper" && s.cursor.x === 17, screen(s));
  s.feed("\x15puts $ans\t");
  check("Tab completes a variable", s.text()[s.cursor.y].includes("$answer"), screen(s));
  s.feed("\x15lre\t");
  check("Tab with many matches shows a menu", screen(s).includes("lrepeat") && screen(s).includes("lreverse"), screen(s));
  s.feed("\x15\x10");
  check("Ctrl-P gives the last command", s.text()[s.cursor.y].includes("set answer 42"), screen(s));
  s.feed("\x15puts hi\r");
  check("puts writes a line", s.text().some((l) => l === "hi"), screen(s));
}

{
  const s = await shell({ files: { "hello.tcl": "puts hello\n", "lib/fib.tcl": "proc fib n {}\n" } });
  s.feed("source he\t");
  check("Tab completes a file name", s.text()[s.cursor.y].includes("source hello.tcl"), screen(s));
  s.feed("\r");
  check("source runs a file", s.text().some((l) => l === "hello"), screen(s));
  s.feed("source li\t");
  check("Tab completes a folder with a slash", s.text()[s.cursor.y].includes("source lib/"), screen(s));
  s.feed("\x15glob */*\r");
  check("glob gives the files of a folder", screen(s).includes("lib/fib.tcl"), screen(s));
}

{
  const s = await shell();
  s.feed("while 1 {}\r");
  check("the compute limit stops a loop", screen(s).includes("compute limit"), screen(s));
  check("the last command used the compute limit", s.lastCompute === 100_000, String(s.lastCompute));
  s.feed("expr {6*7}\r");
  check("a command after the limit runs", s.text().some((l) => l === "42"), screen(s));
  check("a short command uses few compute units", s.lastCompute > 0 && s.lastCompute < 100, String(s.lastCompute));
}

{
  const s = await shell();
  s.vi = true;
  s.feed("puts abc");
  s.feed("\x1b");
  s.feed("0");
  s.feed("w");
  s.feed("D");
  check("vim keys edit the line", s.text()[s.cursor.y].trimEnd().endsWith("puts"), screen(s));
  s.feed("v");
  check("v asks for the editor", s.editorText === "puts ", String(s.editorText));
  s.setLine("puts edited");
  check("setLine puts the text in the line", s.editorText === null && s.text()[s.cursor.y].includes("puts edited"), screen(s));
}

{
  const s = await shell();
  s.feed("set");
  const row = s.cells()[s.cursor.y];
  const at = row.findIndex((c, i) => c.ch === "s" && row[i + 1].ch === "e");
  check("a command name has a color", at >= 0 && row[at].fg !== null, JSON.stringify(row[at]));
  s.resize(40, 8);
  check("a resize keeps the line", s.text()[s.cursor.y].includes("set"), screen(s));
}

console.log(`${count - failed}/${count} shell checks pass`);
process.exit(failed ? 1 : 0);
