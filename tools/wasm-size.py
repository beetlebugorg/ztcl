#!/usr/bin/env python3
# Reports where the bytes of a WebAssembly module are.
#
#   python3 -I tools/wasm-size.py FILE.wasm [--top N] [--match TEXT] [--tsv]
#
# It prints the size of each section, the exports, the largest functions,
# the code bytes for each group of functions, and the largest data
# segments. A group is the first part of the name of a function in the
# name section: for Zig code, that is the source file of the root module
# (`interp` for src/interp.zig) or the first namespace of a library
# (`fmt` for std.fmt). `--match TEXT` lists each function with TEXT in
# its name. `--tsv` prints one line for each function: size, group, name.
#
# The module needs its name section, so build it with no strip.
# SPDX-License-Identifier: BSD-2-Clause
import collections
import gzip
import re
import sys

SECTIONS = {0: "custom", 1: "type", 2: "import", 3: "function", 4: "table", 5: "memory", 6: "global",
            7: "export", 8: "start", 9: "element", 10: "code", 11: "data", 12: "data count", 13: "tag"}


class Reader:
    def __init__(self, data, at=0):
        self.data = data
        self.at = at

    def byte(self):
        b = self.data[self.at]
        self.at += 1
        return b

    def u32(self):
        n = 0
        shift = 0
        while True:
            b = self.byte()
            n |= (b & 0x7F) << shift
            if b < 0x80:
                return n
            shift += 7

    def name(self):
        n = self.u32()
        s = self.data[self.at:self.at + n]
        self.at += n
        return s.decode("utf-8", "replace")

    def skip_init(self):
        # A constant expression ends with the byte 0x0b. The operands of
        # the instructions that an initializer can have are LEB numbers
        # or fixed-size floats, so a walk of the opcodes finds the end.
        while True:
            op = self.byte()
            if op == 0x0B:
                return
            if op in (0x41, 0x42, 0x23, 0xD2):
                self.u32()
            elif op == 0x43:
                self.at += 4
            elif op == 0x44:
                self.at += 8
            elif op == 0xD0:
                self.byte()


def group_of(name):
    # `interp.Interp.findVar` -> interp. A generic keeps the name of its
    # type function: `array_list.Aligned(u8,null).append` -> array_list.
    m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", name)
    return m.group(0) if m else "(no name)"


def parse(data):
    if data[:4] != b"\0asm":
        sys.exit("not a WebAssembly module")
    r = Reader(data, 8)
    sections = []
    imports = 0
    exports = []
    bodies = []
    segments = []
    names = {}
    while r.at < len(data):
        sid = r.byte()
        size = r.u32()
        start = r.at
        end = start + size
        label = SECTIONS.get(sid, str(sid))
        if sid == 0:
            label = "custom: " + r.name()
            if label == "custom: name":
                while r.at < end:
                    sub = r.byte()
                    sub_end = r.u32() + r.at
                    if sub == 1:
                        for _ in range(r.u32()):
                            index = r.u32()
                            names[index] = r.name()
                    r.at = sub_end
        elif sid == 2:
            for _ in range(r.u32()):
                r.name()
                r.name()
                kind = r.byte()
                if kind == 0:
                    r.u32()
                    imports += 1
                elif kind == 1:
                    r.byte()
                    flags = r.byte()
                    r.u32()
                    if flags & 1:
                        r.u32()
                elif kind == 2:
                    flags = r.byte()
                    r.u32()
                    if flags & 1:
                        r.u32()
                elif kind == 3:
                    r.byte()
                    r.byte()
        elif sid == 7:
            for _ in range(r.u32()):
                n = r.name()
                kind = r.byte()
                exports.append((n, kind, r.u32()))
        elif sid == 10:
            for _ in range(r.u32()):
                n = r.u32()
                bodies.append(n)
                r.at += n
        elif sid == 11:
            for _ in range(r.u32()):
                flags = r.u32()
                offset = None
                if flags & 2:
                    r.u32()
                if flags & 1 == 0:
                    at = r.at
                    r.skip_init()
                    init = data[at:r.at]
                    if init[0] == 0x41:
                        offset = Reader(init, 1).u32()
                n = r.u32()
                segments.append((offset, n, data[r.at:r.at + n]))
                r.at += n
        sections.append((label, size))
        r.at = end
    funcs = [(size, names.get(imports + i, "func[%d]" % (imports + i))) for i, size in enumerate(bodies)]
    return sections, exports, funcs, segments


def main():
    args = sys.argv[1:]
    top = 30
    match = None
    tsv = False
    path = None
    while args:
        a = args.pop(0)
        if a == "--top":
            top = int(args.pop(0))
        elif a == "--match":
            match = args.pop(0)
        elif a == "--tsv":
            tsv = True
        else:
            path = a
    if path is None:
        sys.exit("usage: wasm-size.py FILE.wasm [--top N] [--match TEXT] [--tsv]")
    data = open(path, "rb").read()
    sections, exports, funcs, segments = parse(data)
    if tsv:
        for size, name in sorted(funcs, reverse=True):
            print("%d\t%s\t%s" % (size, group_of(name), name))
        return
    if match is not None:
        total = 0
        for size, name in sorted(funcs, reverse=True):
            if match in name:
                total += size
                print("%8d  %s" % (size, name[:150]))
        print("%8d  total" % total)
        return
    print("file: %d bytes, gzip -9: %d bytes" % (len(data), len(gzip.compress(data, 9))))
    print("\nsections")
    for label, size in sections:
        print("%10d  %s" % (size, label))
    kinds = collections.Counter(kind for _, kind, _ in exports)
    print("\nexports: %d functions, %d others" % (kinds[0], len(exports) - kinds[0]))
    code = sum(size for size, _ in funcs)
    print("\nfunctions: %d, %d bytes of code" % (len(funcs), code))
    groups = collections.defaultdict(lambda: [0, 0])
    for size, name in funcs:
        g = groups[group_of(name)]
        g[0] += size
        g[1] += 1
    print("\ncode bytes for each group (the first %d)" % top)
    for name, (size, count) in sorted(groups.items(), key=lambda kv: -kv[1][0])[:top]:
        print("%10d  %5.1f %%  %5d functions  %s" % (size, 100.0 * size / code, count, name))
    print("\nthe largest functions (the first %d)" % top)
    for size, name in sorted(funcs, reverse=True)[:top]:
        print("%10d  %s" % (size, name[:150]))
    print("\ndata segments: %d, %d bytes" % (len(segments), sum(n for _, n, _ in segments)))
    for offset, n, body in sorted(segments, key=lambda s: -s[1])[:8]:
        zeros = body.count(0)
        packed = len(gzip.compress(body, 9))
        where = "passive" if offset is None else "at %d" % offset
        print("%10d  %s, %d zero bytes, gzip -9 %d" % (n, where, zeros, packed))


main()
