#!/usr/bin/env python3
# Makes src/h2/hpack_tables.zig from the text of RFC 7541: the static
# table (appendix A), the Huffman code (appendix B), and the examples
# of appendix C (the header list, the encoded bytes, and the dynamic
# table after each one).
#
#   tools/hpack-tables.py rfc7541.txt > src/h2/hpack_tables.zig
#
# SPDX-License-Identifier: BSD-2-Clause
import re
import sys

lines = open(sys.argv[1]).read().split("\n")
# Drop the page breaks: the footer, the form feed, and the header.
text = []
for l in lines:
    if l.startswith("\f") or re.match(r"^Peon & Ruellan", l) or re.match(r"^RFC 7541 ", l):
        continue
    text.append(l)

def section(start, end):
    i = next(k for k, l in enumerate(text) if l.startswith(start))
    j = next(k for k, l in enumerate(text) if k > i and l.startswith(end))
    return text[i:j]

static = []
for l in section("Appendix A.  Static", "Appendix B."):
    m = re.match(r"^\s+\| (\d+)\s+\| (\S+)\s+\| (.*?)\s*\|$", l)
    if m:
        static.append((int(m.group(1)), m.group(2), m.group(3)))
assert [s[0] for s in static] == list(range(1, 62)), len(static)

huff = []
for l in section("Appendix B.  Huffman", "Appendix C."):
    m = re.match(r"^\s+(?:'.'\s+|EOS\s+)?\(\s*(\d+)\)\s+\|([01|]+)\s+([0-9a-f]+)\s+\[\s*(\d+)\]", l)
    if m:
        bits = m.group(2).replace("|", "")
        code = int(m.group(3), 16)
        n = int(m.group(4))
        assert len(bits) == n and int(bits, 2) == code
        huff.append((int(m.group(1)), code, n))
assert [h[0] for h in huff] == list(range(257)), len(huff)
# The code is canonical: sorted by length and then by symbol, each code
# is the one before plus one, shifted to its length.
order = sorted(huff, key=lambda h: (h[2], h[0]))
code = 0
prev = order[0][2]
for k, (s, c, n) in enumerate(order):
    if k > 0:
        code = (code + 1) << (n - prev)
    assert c == code, (s, hex(c), hex(code))
    prev = n

examples = []
body = section("Appendix C.  Examples", "Authors' Addresses")
k = 0
while k < len(body):
    m = re.match(r"^(C\.[3-6]\.\d)\.\s+(.*)$", body[k])
    if not m:
        k += 1
        continue
    name = m.group(1) + " " + m.group(2)
    k += 1
    while not body[k].strip().startswith("Header list to encode"):
        k += 1
    k += 2
    headers = []
    while body[k].strip():
        l = body[k].strip()
        i = l.index(": ", 1)
        headers.append((l[:i], l[i + 2:]))
        k += 1
    while not body[k].strip().startswith("Hex dump"):
        k += 1
    k += 2
    data = b""
    while body[k].strip():
        hexpart = body[k].split("|")[0]
        data += bytes.fromhex(hexpart.replace(" ", ""))
        k += 1
    while not body[k].strip().startswith("Dynamic Table (after decoding)"):
        k += 1
    k += 2
    table = []
    while True:
        l = body[k].strip()
        mm = re.match(r"^\[\s*\d+\] \(s =\s*(\d+)\) (.*)$", l)
        if mm:
            e = mm.group(2)
            i = e.index(": ", 1)
            table.append([e[:i], e[i + 2:], int(mm.group(1))])
            k += 1
            continue
        mm = re.match(r"^Table size:\s*(\d+)$", l)
        if not mm:
            # A long entry goes on to the next line.
            table[-1][1] += " " + l
            k += 1
            continue
        size = int(mm.group(1))
        break
    for n, v, sz in table:
        assert len(n) + len(v) + 32 == sz, (n, v, sz)
    assert sum(t[2] for t in table) == size
    table = [(n, v) for n, v, _ in table]
    examples.append((name, headers, data, table, size))
assert len(examples) == 12, len(examples)

def zs(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

out = []
out.append("//! The tables and the examples of RFC 7541, from")
out.append("//! tools/hpack-tables.py. Do not edit.")
out.append("//!")
out.append("//! SPDX-License-Identifier: BSD-2-Clause")
out.append("")
out.append("pub const Field = struct { name: []const u8, value: []const u8 };")
out.append("")
out.append("/// Appendix A: the entries 1 to 61 of the static table.")
out.append("pub const static = [61]Field{")
for i, n, v in static:
    out.append("    .{ .name = %s, .value = %s }," % (zs(n), zs(v)))
out.append("};")
out.append("")
out.append("/// Appendix B: the code of each symbol (0 to 255, and 256 for EOS),")
out.append("/// aligned to the least significant bit, and its length in bits.")
out.append("pub const huffman_code = [257]u32{")
for s, c, n in huff:
    out.append("    0x%x," % c)
out.append("};")
out.append("pub const huffman_len = [257]u8{")
row = []
for s, c, n in huff:
    row.append(str(n))
for i in range(0, 257, 16):
    out.append("    " + ", ".join(row[i:i + 16]) + ",")
out.append("};")
out.append("")
out.append("pub const Example = struct {")
out.append("    name: []const u8,")
out.append("    headers: []const Field,")
out.append("    encoded: []const u8,")
out.append("    /// The dynamic table after the block, newest entry first.")
out.append("    table: []const Field,")
out.append("    table_size: usize,")
out.append("};")
out.append("")
out.append("/// Appendix C.3 to C.6: four groups of three blocks. Each group uses one")
out.append("/// encoder and one decoder. C.4 and C.6 use the Huffman code for each")
out.append("/// string, and C.5 and C.6 have a table of 256 bytes.")
out.append("pub const examples = [12]Example{")
for name, headers, data, table, size in examples:
    out.append("    .{")
    out.append("        .name = %s," % zs(name))
    out.append("        .headers = &.{")
    for n, v in headers:
        out.append("            .{ .name = %s, .value = %s }," % (zs(n), zs(v)))
    out.append("        },")
    out.append("        .encoded = \"" + "".join("\\x%02x" % b for b in data) + "\",")
    out.append("        .table = &.{")
    for n, v in table:
        out.append("            .{ .name = %s, .value = %s }," % (zs(n), zs(v)))
    out.append("        },")
    out.append("        .table_size = %d," % size)
    out.append("    },")
out.append("};")
print("\n".join(out))
