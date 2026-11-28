// Tests the files of the host and ztcl::typeset and ztcl::pdf in the
// WebAssembly builds: the option `files` of Interp.create, binary reads
// and writes, and a PDF that the page reads back with readFile.
//
//     zig build wasm wasm-shell
//     node tools/wasm-typeset.mjs zig-out/lib/ztcl.wasm zig-out/lib/ztcl-shell.wasm
//
// SPDX-License-Identifier: BSD-2-Clause

import { Interp } from "../web/ztcl.mjs";
import { readFileSync } from "node:fs";

const core = new WebAssembly.Module(readFileSync(process.argv[2] ?? "zig-out/lib/ztcl.wasm"));
const site = new WebAssembly.Module(readFileSync(process.argv[3] ?? "zig-out/lib/ztcl-shell.wasm"));
const font = readFileSync(new URL("../book/fonts/SourceSerif4-Regular.ttf", import.meta.url));
let failed = 0;
let count = 0;

function check(name, ok, detail) {
  count++;
  if (!ok) {
    failed++;
    console.log(`FAIL ${name}\n${detail}`);
  }
}

const bytes = Uint8Array.of(0, 0x41, 0x7f, 0x80, 0xc3, 0xff, 0x0a);
{
  // ztcl.wasm: read-only files from the host, read as text or as bytes.
  const t = await Interp.create(core, { allow: ["file"], files: { "data/b.bin": bytes } });
  const r = t.eval(`set f [open data/b.bin rb]; set d [read $f]; close $f
    set g [open data/b.bin]; set e [read $g]; close $g
    list [string length $d] [scan [string index $d 5] %c] [string length $e]`);
  // A text read gives the bytes as UTF-8: C3 FF is no character, so the
  // text is one character shorter.
  check("a binary read gives a character for each byte", r.ok && r.result === "7 255 6", JSON.stringify(r));
  const w = t.eval("catch {open out.txt w} m; set m");
  check("ztcl.wasm has no writes", w.result.includes("read-only file system"), w.result);
  const p = t.eval("package require ztcl::typeset");
  check("ztcl.wasm has no ztcl::typeset", !p.ok, p.result);
}

{
  // ztcl-shell.wasm: the typesetter, with a font from the host, and a
  // PDF that the page reads back.
  const t = await Interp.create(site, { allow: ["file"], files: { "book/fonts/SourceSerif4-Regular.ttf": font } });
  const r = t.eval(`package require ztcl::typeset; package require ztcl::pdf
    set f [open book/fonts/SourceSerif4-Regular.ttf rb]; set data [read $f]; close $f
    set font [ztcl::typeset font load $data]
    set lines [ztcl::typeset break "In olden times when wishing still helped one, there lived a king" -width 120 -font $font -size 10]
    set svg [ztcl::typeset svg "Hello" -width 200 -font $font -size 12 -family "Source Serif 4"]
    set doc [ztcl::pdf create]
    set fn [ztcl::pdf font $doc $data]
    set p [ztcl::pdf page $doc]
    ztcl::pdf text $doc $p $fn 12 72 720 "Hello"
    set o [open out/hello.pdf wb]; puts -nonewline $o [ztcl::pdf bytes $doc]; close $o
    set g [open book/fonts/SourceSerif4-Regular.ttf]; fconfigure $g -translation binary; set e [read $g]; close $g
    list [llength $lines] [string match <svg* $svg] [expr {$e eq $data}]`);
  check("ztcl-shell.wasm breaks lines with a font of the host", r.ok && r.result === "3 1 1", JSON.stringify(r));
  check("fileNames lists the written file", t.fileNames().join() === "out/hello.pdf", t.fileNames().join());
  const pdf = t.readFile("out/hello.pdf");
  const head = pdf && new TextDecoder().decode(pdf.slice(0, 5));
  const tail = pdf && new TextDecoder().decode(pdf.slice(-6));
  check("readFile gives the bytes of the PDF", head === "%PDF-" && tail.includes("%%EOF"), `${head} ${tail}`);
  check("the PDF has the bytes of the font", pdf && pdf.length > 2000 && pdf.some((b) => b >= 0x80), String(pdf?.length));
  check("readFile of a missing file is null", t.readFile("nope") === null, "");
}

console.log(`${count - failed}/${count} typeset checks pass`);
process.exit(failed ? 1 : 0);
