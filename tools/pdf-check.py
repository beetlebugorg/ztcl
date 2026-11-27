#!/usr/bin/env python3
"""Checks the structure of PDF files from ztcl::pdf.

Usage: python3 -I tools/pdf-check.py FILE.pdf...

For each file it checks, from ISO 32000-2:

- the header `%PDF-1.x`, the `startxref` offset, and the `%%EOF` line;
- the cross-reference table: each entry of an object in use points at
  the line `N 0 obj` of that object, and `/Size` is the count of entries;
- the trailer: `/Root` is a catalog with `/Pages`, and `/Info` exists;
- each stream: `/Length` is the count of bytes before `endstream`, and a
  `/FlateDecode` stream inflates;
- the page tree: `/Count` is the count of `/Kids`, and each kid is a page;
- each Type 0 font: a CIDFontType2 descendant, a ToUnicode map, and an
  embedded TrueType program whose table directory, table checksums, and
  `loca` offsets are valid.

With `qpdf` on the PATH, it also runs `qpdf --check` on each file. The
tool uses only the Python standard library. It exits with 1 on the first
file with a problem.
"""

import re
import shutil
import struct
import subprocess
import sys
import zlib


def fail(path, msg):
    print(f"{path}: {msg}")
    sys.exit(1)


def objects(path, data):
    m = re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", data)
    if not m:
        fail(path, "no startxref and %%EOF at the end")
    xref = int(m.group(1))
    if data[xref:xref + 4] != b"xref":
        fail(path, f"startxref {xref} does not point at the xref table")
    lines = data[xref:].split(b"\n")
    first, count = map(int, lines[1].split())
    if first != 0:
        fail(path, "the xref table does not start at object 0")
    offsets = {}
    for i in range(count):
        e = lines[2 + i]
        if len(e) != 19 and len(e) != 20:
            fail(path, f"xref entry {i} is not 20 bytes")
        off, gen, kind = e[:10], e[11:16], e[17:18]
        if kind == b"n":
            n = int(off)
            if not data[n:].startswith(b"%d 0 obj" % i):
                fail(path, f"xref entry {i} points at offset {n}, and object {i} is not there")
            offsets[i] = n
    trailer = data[data.index(b"trailer", xref):]
    size = int(re.search(rb"/Size (\d+)", trailer).group(1))
    if size != count:
        fail(path, f"/Size {size} differs from the {count} xref entries")
    objs = {}
    for i, n in offsets.items():
        end = data.index(b"endobj", n)
        objs[i] = data[n:end]
    root = int(re.search(rb"/Root (\d+) 0 R", trailer).group(1))
    if not re.search(rb"/Info (\d+) 0 R", trailer):
        fail(path, "the trailer has no /Info")
    return objs, root


def stream_of(path, num, body):
    m = re.search(rb"/Length (\d+)", body)
    s = body.find(b"stream\n")
    if not m or s < 0:
        return None
    length = int(m.group(1))
    raw = body[s + 7:s + 7 + length]
    if body[s + 7 + length:s + 7 + length + 10] != b"\nendstream":
        fail(path, f"object {num}: /Length {length} does not end at endstream")
    if b"/FlateDecode" in body[:s] and b"/DCTDecode" not in body[:s]:
        try:
            return zlib.decompress(raw)
        except zlib.error as e:
            fail(path, f"object {num}: the Flate data does not inflate: {e}")
    return raw


def check_truetype(path, num, font):
    if len(font) < 12:
        fail(path, f"object {num}: the font program is too short")
    n = struct.unpack(">H", font[4:6])[0]
    tables = {}
    for i in range(n):
        tag, csum, off, length = struct.unpack(">4sIII", font[12 + 16 * i:28 + 16 * i])
        if off + length > len(font):
            fail(path, f"object {num}: the table {tag!r} is past the end of the font")
        t = font[off:off + length]
        padded = t + b"\0" * (-len(t) % 4)
        total = sum(struct.unpack(f">{len(padded) // 4}I", padded)) & 0xFFFFFFFF
        if tag != b"head" and total != csum:
            fail(path, f"object {num}: the checksum of {tag!r} is wrong")
        tables[tag] = t
    for need in (b"head", b"hhea", b"maxp", b"hmtx", b"loca", b"glyf"):
        if need not in tables:
            fail(path, f"object {num}: the font has no {need!r} table")
    glyphs = struct.unpack(">H", tables[b"maxp"][4:6])[0]
    long_loca = struct.unpack(">h", tables[b"head"][50:52])[0] == 1
    loca = tables[b"loca"]
    fmt, step = (">I", 4) if long_loca else (">H", 2)
    prev = 0
    for g in range(glyphs + 1):
        v = struct.unpack(fmt, loca[g * step:g * step + step])[0] * (1 if long_loca else 2)
        if v < prev or v > len(tables[b"glyf"]):
            fail(path, f"object {num}: loca entry {g} is out of order or past glyf")
        prev = v


def check(path):
    data = open(path, "rb").read()
    if not re.match(rb"%PDF-1\.[0-7]\n", data):
        fail(path, "no PDF header")
    objs, root = objects(path, data)
    streams = {}
    for i, body in objs.items():
        s = stream_of(path, i, body)
        if s is not None:
            streams[i] = s
    cat = objs[root]
    if b"/Type /Catalog" not in cat:
        fail(path, "/Root is not a catalog")
    pages = int(re.search(rb"/Pages (\d+) 0 R", cat).group(1))
    tree = objs[pages]
    kids = re.findall(rb"(\d+) 0 R", tree[tree.index(b"/Kids"):])
    count = int(re.search(rb"/Count (\d+)", tree).group(1))
    if count != len(kids):
        fail(path, f"the page tree has /Count {count} and {len(kids)} kids")
    for k in kids:
        if b"/Type /Page " not in objs[int(k)]:
            fail(path, f"object {int(k)} of /Kids is not a page")
    fonts = 0
    for i, body in objs.items():
        if b"/Subtype /Type0" not in body:
            continue
        fonts += 1
        desc = int(re.search(rb"/DescendantFonts \[(\d+) 0 R\]", body).group(1))
        if b"/CIDFontType2" not in objs[desc]:
            fail(path, f"object {i}: the descendant font is not a CIDFontType2")
        tu = int(re.search(rb"/ToUnicode (\d+) 0 R", body).group(1))
        if b"beginbfchar" not in streams.get(tu, b""):
            fail(path, f"object {i}: the ToUnicode map has no entries")
        fd = int(re.search(rb"/FontDescriptor (\d+) 0 R", objs[desc]).group(1))
        ff = int(re.search(rb"/FontFile2 (\d+) 0 R", objs[fd]).group(1))
        check_truetype(path, ff, streams[ff])
    if shutil.which("qpdf"):
        r = subprocess.run(["qpdf", "--check", path], capture_output=True, text=True)
        if r.returncode != 0:
            fail(path, "qpdf --check: " + (r.stdout + r.stderr).strip().splitlines()[-1])
    print(f"{path}: ok, {len(objs)} objects, {count} pages, {fonts} fonts" + (", qpdf ok" if shutil.which("qpdf") else ""))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        check(p)
