#!/usr/bin/env python3
"""Writes src/text/tables.zig, the break and width tables of ztcl::text.

Usage: python3 -I tools/text-gen.py UCD_DIR | zig fmt --stdin > src/text/tables.zig

UCD_DIR has these files of the Unicode Character Database (the data
of Unicode, Inc., under the Unicode License V3):

- auxiliary/GraphemeBreakProperty.txt, auxiliary/WordBreakProperty.txt,
  and auxiliary/SentenceBreakProperty.txt: the break classes of UAX #29.
- DerivedCoreProperties.txt: Indic_Conjunct_Break and
  Default_Ignorable_Code_Point.
- emoji/emoji-data.txt: Extended_Pictographic, Emoji, and
  Emoji_Presentation (UTS #51).
- EastAsianWidth.txt: the East_Asian_Width of UAX #11.
- extracted/DerivedGeneralCategory.txt: the general category.

Each code point gets one 32-bit row of properties (see `Props` in
src/text/seg.zig). The file keeps the distinct rows in `rows` and maps
a code point to its row with two stages: `stage1[cp >> SHIFT]` is the
number of a block, and `stage2[block << SHIFT | cp & MASK]` is the
number of the row. Equal blocks are stored once. The script tries each
block size and keeps the smallest.
"""
import os
import sys

GCB = ["Other", "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator", "Prepend", "SpacingMark", "L", "V", "T", "LV", "LVT"]
WB = ["Other", "CR", "LF", "Newline", "Extend", "ZWJ", "Regional_Indicator", "Format", "Katakana", "Hebrew_Letter", "ALetter",
      "Single_Quote", "Double_Quote", "MidNumLet", "MidLetter", "MidNum", "Numeric", "ExtendNumLet", "WSegSpace"]
SB = ["Other", "CR", "LF", "Extend", "Sep", "Format", "Sp", "Lower", "Upper", "OLetter", "Numeric", "ATerm", "SContinue", "STerm", "Close"]
INCB = ["None", "Linker", "Consonant", "Extend"]
N = 0x110000


def ranges(path):
    """Yields (first, last, fields) for each data line of a UCD file."""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(";")]
            r = parts[0].split("..")
            lo = int(r[0], 16)
            hi = int(r[-1], 16)
            yield lo, hi, parts[1:]


def prop(path, names, default=0):
    out = bytearray([default]) * N
    index = {n: i for i, n in enumerate(names)}
    for lo, hi, f in ranges(path):
        v = index[f[0]]
        for cp in range(lo, hi + 1):
            out[cp] = v
    return out


def flag(path, name, key=None):
    out = bytearray(N)
    for lo, hi, f in ranges(path):
        if f[0] != name or (key is not None and f[1] != key):
            continue
        for cp in range(lo, hi + 1):
            out[cp] = 1
    return out


def main():
    ucd = sys.argv[1]
    j = lambda *p: os.path.join(ucd, *p)
    gcb = prop(j("auxiliary", "GraphemeBreakProperty.txt"), GCB)
    wb = prop(j("auxiliary", "WordBreakProperty.txt"), WB)
    sb = prop(j("auxiliary", "SentenceBreakProperty.txt"), SB)
    incb = bytearray(N)
    for lo, hi, f in ranges(j("DerivedCoreProperties.txt")):
        if f[0] == "InCB":
            for cp in range(lo, hi + 1):
                incb[cp] = INCB.index(f[1])
    ignorable = flag(j("DerivedCoreProperties.txt"), "Default_Ignorable_Code_Point")
    ep = flag(j("emoji", "emoji-data.txt"), "Extended_Pictographic")
    emoji = flag(j("emoji", "emoji-data.txt"), "Emoji")
    epres = flag(j("emoji", "emoji-data.txt"), "Emoji_Presentation")
    eaw = bytearray([1]) * N
    for lo, hi, f in ranges(j("EastAsianWidth.txt")):
        v = {"W": 2, "F": 2, "A": 3}.get(f[0], 1)
        for cp in range(lo, hi + 1):
            eaw[cp] = v
    gc = [""] * N
    for lo, hi, f in ranges(j("extracted", "DerivedGeneralCategory.txt")):
        for cp in range(lo, hi + 1):
            gc[cp] = f[0]
    alnum = bytearray(N)
    width = bytearray(N)
    for cp in range(N):
        c = gc[cp]
        alnum[cp] = 1 if c[:1] in ("L", "N") else 0
        # The width of one code point: 0 for marks, formats, controls,
        # default ignorables, and the medial and final jamo of Hangul;
        # 2 for East_Asian_Width W and F and for Emoji_Presentation;
        # 3 for ambiguous (one or two by the option); else 1.
        # U+00AD SOFT HYPHEN is Cf, and terminals show it in one column.
        if cp != 0xAD and (c in ("Mn", "Me", "Cf", "Cc", "Zl", "Zp") or ignorable[cp] or GCB[gcb[cp]] in ("V", "T")):
            w = 0
        elif epres[cp]:
            w = 2
        else:
            w = eaw[cp]
        width[cp] = w
    rows = {}
    order = []
    per = [0] * N
    for cp in range(N):
        r = (gcb[cp] | incb[cp] << 4 | ep[cp] << 6 | wb[cp] << 7 | sb[cp] << 12 | width[cp] << 16
             | emoji[cp] << 18 | epres[cp] << 19 | alnum[cp] << 20)
        k = rows.get(r)
        if k is None:
            k = len(order)
            rows[r] = k
            order.append(r)
        per[cp] = k
    assert len(order) < 256, len(order)
    # Three stages: stage1[cp >> (LEAF + MID)] is a middle block,
    # stage2[mid << MID | (cp >> LEAF) & (1 << MID) - 1] is a leaf block,
    # and stage3[leaf << LEAF | cp & (1 << LEAF) - 1] is the row.
    best = None
    for lb in range(3, 9):
        for mb in range(2, 10):
            leaves = {}
            lid = []
            s3 = []
            for i in range(N >> lb):
                key = bytes(per[i << lb:(i + 1) << lb])
                k = leaves.get(key)
                if k is None:
                    k = len(leaves)
                    leaves[key] = k
                    s3.extend(key)
                lid.append(k)
            mids = {}
            s1 = []
            s2 = []
            for i in range(len(lid) >> mb):
                key = tuple(lid[i << mb:(i + 1) << mb])
                k = mids.get(key)
                if k is None:
                    k = len(mids)
                    mids[key] = k
                    s2.extend(key)
                s1.append(k)
            w1 = 1 if len(mids) <= 256 else 2
            w2 = 1 if len(leaves) <= 256 else 2
            total = len(s1) * w1 + len(s2) * w2 + len(s3) + len(order) * 4 + 128
            if best is None or total < best[0]:
                best = (total, lb, mb, s1, s2, s3, w1, w2)
    total, lb, mb, s1, s2, s3, w1, w2 = best
    w = sys.stdout.write
    w("//! The break and width tables of ztcl::text, from the Unicode\n")
    w("//! Character Database 18.0.0. tools/text-gen.py writes this file.\n")
    w("//! Do not edit it.\n")
    w("//!\n")
    w("//! `rows` has each distinct row of properties (`Props` of seg.zig).\n")
    w("//! The row of a code point is `rows[stage3[leaf << leaf_bits | cp &\n")
    w("//! leaf_mask]]`, with `leaf = stage2[mid << mid_bits | (cp >>\n")
    w("//! leaf_bits) & mid_mask]` and `mid = stage1[cp >> (leaf_bits +\n")
    w("//! mid_bits)]`. `ascii` is the row of each ASCII code point.\n")
    w("//! The data is %d bytes.\n" % total)
    w("//!\n")
    w("//! SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n\n")
    w("pub const leaf_bits = %d;\n" % lb)
    w("pub const mid_bits = %d;\n" % mb)
    w("pub const leaf_mask = %d;\n" % ((1 << lb) - 1))
    w("pub const mid_mask = %d;\n\n" % ((1 << mb) - 1))

    def arr(name, typ, vals, per_line, fmt):
        w("pub const %s = [_]%s{\n" % (name, typ))
        for i in range(0, len(vals), per_line):
            w("    " + ", ".join(fmt % v for v in vals[i:i + per_line]) + ",\n")
        w("};\n\n")

    arr("rows", "u32", order, 8, "0x%06x")
    arr("ascii", "u8", per[:128], 32, "%d")
    arr("stage1", "u8" if w1 == 1 else "u16", s1, 24, "%d")
    arr("stage2", "u8" if w2 == 1 else "u16", s2, 24, "%d")
    arr("stage3", "u8", s3, 32, "%d")
    sys.stderr.write("rows %d, leaf %d, mid %d, stage1 %d, stage2 %d, stage3 %d, total %d bytes\n" % (len(order), lb, mb, len(s1), len(s2), len(s3), total))

if __name__ == "__main__":
    main()
