# The AArch64 part of tools/jit-asm-golden.sh.
#
#   python3 -I tools/jit-asm-a64.py WORK table 0   writes WORK/a64_golden.zig
#   python3 -I tools/jit-asm-a64.py WORK random N  writes WORK/rows.txt
#
# Each form of src/jit/a64.zig has its kinds of registers, its edge
# values, and the text of the assembler. The table mode puts each
# register in each register place with fixed values, then each edge
# value with fixed registers. The random mode picks each field at random
# in its range. `zig cc -target aarch64-linux-gnu -c` assembles the
# text, and the tool reads the word of each row from the symbols of the
# object file.
# SPDX-License-Identifier: BSD-2-Clause
import random, struct, subprocess, sys

work, mode, total = sys.argv[1], sys.argv[2], int(sys.argv[3])

# The register kinds: g a general register, z a general register or the
# zero register, s a general register or sp, d a double register.
GREGS = [r for r in range(31) if r != 18]
KINDS = {"g": GREGS, "z": GREGS + [32], "s": GREGS + [31], "d": list(range(32))}


def x(n):
    return {31: "sp", 32: "xzr"}.get(n, "x%d" % n)


def w(n):
    return {31: "wsp", 32: "wzr"}.get(n, "w%d" % n)


SIZES = ["x", "w", "b", "d"]
SCALE = {"x": 3, "w": 2, "b": 0, "d": 3}


def rt(k, n):
    z = SIZES[k]
    return {"x": x, "w": w, "b": w, "d": lambda r: "d%d" % r}[z](n)


def ls(base, k, store, unscaled):
    z = SIZES[k]
    m = ("st" if store else "ld") + ("ur" if unscaled else "r") + ("b" if z == "b" else "")
    return m


OPS = ["add", "adds", "sub", "subs", "and", "orr", "eor"]
SHIFTS = ["lsl", "lsr", "asr"]
CONDS = "eq ne hs lo mi pl vs vc hi ls ge lt gt le".split()
FOPS = ["fadd", "fsub", "fmul", "fdiv"]
MASKS = [1, 3, 7, 0xFF, 0xFFFF, 0xFFFFFFFF, (1 << 63) - 1]


def u12s(k):
    s = SCALE[SIZES[k]]
    return [0, 1 << s, 123 << s, 4095 << s]


# Each form: (kinds of a b c, edge tuples (i, j, k) or a function of k,
# a random tuple, the text). `rnd` is the random source.
def forms():
    F = {}
    F["mov_rr"] = ("sz", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "mov %s, %s" % (x(a), x(b)))
    F["mov_rr32"] = ("gz", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "mov %s, %s" % (w(a), w(b)))
    for name in ("movz", "movk", "movn"):
        F[name] = ("g", [(i, j, 0) for i in (0, 1, 0x7FFF, 0xFFFF) for j in (0, 16, 32, 48)],
                   lambda r: (r.randrange(65536), r.choice((0, 16, 32, 48)), 0),
                   (lambda nm: lambda a, b, c, i, j, k: "%s %s, #%d, lsl #%d" % (nm, x(a), i, j))(name))
    F["movz_w"] = ("g", [(i, 0, 0) for i in (0, 42, 0xFFFF)], lambda r: (r.randrange(65536), 0, 0),
                   lambda a, b, c, i, j, k: "movz %s, #%d" % (w(a), i))
    for name, store in (("ldr_u", False), ("str_u", True)):
        F[name] = ("gs", [(i, 0, k) for k in range(4) for i in u12s(k)],
                   lambda r: (lambda k: (r.randrange(4096) << SCALE[SIZES[k]], 0, k))(r.randrange(4)),
                   (lambda st: lambda a, b, c, i, j, k: "%s %s, [%s, #%d]" % (ls(b, k, st, False), rt(k, a), x(b), i))(store))
    for name, store in (("ldur", False), ("stur", True)):
        F[name] = ("gs", [(i, 0, k) for k in range(4) for i in (-256, -1, 0, 1, 255)],
                   lambda r: (r.randrange(-256, 256), 0, r.randrange(4)),
                   (lambda st: lambda a, b, c, i, j, k: "%s %s, [%s, #%d]" % (ls(b, k, st, True), rt(k, a), x(b), i))(store))
    for name, store in (("ldr_r", False), ("str_r", True)):
        F[name] = ("gsz", [(0, 0, k) for k in range(4)], lambda r: (0, 0, r.randrange(4)),
                   (lambda st: lambda a, b, c, i, j, k: "%s %s, [%s, %s]" % (ls(b, k, st, False), rt(k, a), x(b), x(c)))(store))
    pairs = [-512, -8, 0, 8, 504]
    rpair = lambda r: (8 * r.randrange(-64, 64), 0, 0)
    F["stp_pre"] = ("zzs", [(i, 0, 0) for i in pairs], rpair, lambda a, b, c, i, j, k: "stp %s, %s, [%s, #%d]!" % (x(a), x(b), x(c), i))
    F["stp_post"] = ("zzs", [(i, 0, 0) for i in pairs], rpair, lambda a, b, c, i, j, k: "stp %s, %s, [%s], #%d" % (x(a), x(b), x(c), i))
    F["stp_off"] = ("zzs", [(i, 0, 0) for i in pairs], rpair, lambda a, b, c, i, j, k: "stp %s, %s, [%s, #%d]" % (x(a), x(b), x(c), i))
    # A load pair needs two different registers.
    F["ldp_pre"] = ("ggs", [(i, 0, 0) for i in pairs], rpair, lambda a, b, c, i, j, k: "ldp %s, %s, [%s, #%d]!" % (x(a), x(b), x(c), i))
    F["ldp_post"] = ("ggs", [(i, 0, 0) for i in pairs], rpair, lambda a, b, c, i, j, k: "ldp %s, %s, [%s], #%d" % (x(a), x(b), x(c), i))
    F["ldp_off"] = ("ggs", [(i, 0, 0) for i in pairs], rpair, lambda a, b, c, i, j, k: "ldp %s, %s, [%s, #%d]" % (x(a), x(b), x(c), i))
    imm12 = [(i, j, 0) for i in (0, 1, 4095) for j in (0, 1)]
    rimm12 = lambda r: (r.randrange(4096), r.randrange(2), 0)
    sh12 = lambda j: ", lsl #12" if j else ""
    F["add_i"] = ("ss", imm12, rimm12, lambda a, b, c, i, j, k: "add %s, %s, #%d%s" % (x(a), x(b), i, sh12(j)))
    F["sub_i"] = ("ss", imm12, rimm12, lambda a, b, c, i, j, k: "sub %s, %s, #%d%s" % (x(a), x(b), i, sh12(j)))
    F["adds_i"] = ("gs", imm12, rimm12, lambda a, b, c, i, j, k: "adds %s, %s, #%d%s" % (x(a), x(b), i, sh12(j)))
    F["subs_i"] = ("gs", imm12, rimm12, lambda a, b, c, i, j, k: "subs %s, %s, #%d%s" % (x(a), x(b), i, sh12(j)))
    F["cmp_i"] = ("s", [(i, 0, 0) for i in (0, 1, 4095)], lambda r: (r.randrange(4096), 0, 0), lambda a, b, c, i, j, k: "cmp %s, #%d" % (x(a), i))
    F["cmp_wi"] = ("s", [(i, 0, 0) for i in (0, 1, 4095)], lambda r: (r.randrange(4096), 0, 0), lambda a, b, c, i, j, k: "cmp %s, #%d" % (w(a), i))
    F["cmp_wr"] = ("zz", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "cmp %s, %s" % (w(a), w(b)))
    F["op_r"] = ("zzz", [(i, j, k) for k in range(len(OPS)) for j in range(3) for i in (0, 1, 63)],
                 lambda r: (r.randrange(64), r.randrange(3), r.randrange(len(OPS))),
                 lambda a, b, c, i, j, k: "%s %s, %s, %s, %s #%d" % (OPS[k], x(a), x(b), x(c), SHIFTS[j], i))
    F["cmp_r"] = ("zz", [(i, j, 0) for j in range(3) for i in (0, 1, 63)], lambda r: (r.randrange(64), r.randrange(3), 0),
                  lambda a, b, c, i, j, k: "cmp %s, %s, %s #%d" % (x(a), x(b), SHIFTS[j], i))
    F["and_i"] = ("sg", [(m, 0, 0) for m in MASKS], lambda r: ((1 << r.randrange(1, 64)) - 1, 0, 0),
                  lambda a, b, c, i, j, k: "and %s, %s, #%d" % (x(a), x(b), i))
    F["tst_i"] = ("g", [(m, 0, 0) for m in MASKS], lambda r: ((1 << r.randrange(1, 64)) - 1, 0, 0),
                  lambda a, b, c, i, j, k: "tst %s, #%d" % (x(a), i))
    for name in ("mul", "smulh", "sdiv"):
        F[name] = ("zzz", [(0, 0, 0)], lambda r: (0, 0, 0), (lambda nm: lambda a, b, c, i, j, k: "%s %s, %s, %s" % (nm, x(a), x(b), x(c)))(name))
    F["msub"] = ("zzz", [(0, j, 0) for j in (0, 5, 30, 32)], lambda r: (0, r.choice(KINDS["z"]), 0),
                 lambda a, b, c, i, j, k: "msub %s, %s, %s, %s" % (x(a), x(b), x(c), x(j)))
    F["asr_i"] = ("zz", [(i, 0, 0) for i in (0, 1, 63)], lambda r: (r.randrange(64), 0, 0), lambda a, b, c, i, j, k: "asr %s, %s, #%d" % (x(a), x(b), i))
    F["lsl_i"] = ("zz", [(i, 0, 0) for i in (1, 3, 63)], lambda r: (r.randrange(1, 64), 0, 0), lambda a, b, c, i, j, k: "lsl %s, %s, #%d" % (x(a), x(b), i))
    F["cset"] = ("g", [(0, 0, k) for k in range(14)], lambda r: (0, 0, r.randrange(14)), lambda a, b, c, i, j, k: "cset %s, %s" % (x(a), CONDS[k]))
    F["b"] = ("", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "b NEXT")
    F["bcond"] = ("", [(0, 0, k) for k in range(14)], lambda r: (0, 0, r.randrange(14)), lambda a, b, c, i, j, k: "b.%s NEXT" % CONDS[k])
    F["cbz"] = ("z", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "cbz %s, NEXT" % x(a))
    F["cbnz"] = ("z", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "cbnz %s, NEXT" % x(a))
    F["cbz_w"] = ("z", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "cbz %s, NEXT" % w(a))
    F["cbnz_w"] = ("z", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "cbnz %s, NEXT" % w(a))
    F["br"] = ("g", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "br %s" % x(a))
    F["blr"] = ("g", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "blr %s" % x(a))
    F["ret"] = ("", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "ret")
    F["brk"] = ("", [(i, 0, 0) for i in (0, 1, 0xFFFF)], lambda r: (r.randrange(65536), 0, 0), lambda a, b, c, i, j, k: "brk #%d" % i)
    F["udf"] = ("", [(i, 0, 0) for i in (0, 1, 0xFFFF)], lambda r: (r.randrange(65536), 0, 0), lambda a, b, c, i, j, k: "udf #%d" % i)
    F["nop"] = ("", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "nop")
    F["fmov_dd"] = ("dd", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "fmov d%d, d%d" % (a, b))
    F["fmov_dx"] = ("dz", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "fmov d%d, %s" % (a, x(b)))
    F["fmov_xd"] = ("zd", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "fmov %s, d%d" % (x(a), b))
    F["fop"] = ("ddd", [(0, 0, k) for k in range(4)], lambda r: (0, 0, r.randrange(4)),
                lambda a, b, c, i, j, k: "%s d%d, d%d, d%d" % (FOPS[k], a, b, c))
    F["fcmp"] = ("dd", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "fcmp d%d, d%d" % (a, b))
    F["scvtf"] = ("dz", [(0, 0, 0)], lambda r: (0, 0, 0), lambda a, b, c, i, j, k: "scvtf d%d, %s" % (a, x(b)))
    return F


FORMS = forms()


def fixed_regs(kinds):
    # The registers of the edge rows: x1, x2, x3 (sp for a base place).
    return [1, 2, 3][:len(kinds)]


def valid(name, regs):
    kinds = FORMS[name][0]
    # sp and the zero register cannot meet in one move.
    if name == "mov_rr" and sorted(regs[:2]) == [31, 32]:
        return False
    if name.startswith("ldp") and regs[0] == regs[1]:
        return False
    # A load with write-back from its own base is unpredictable.
    if name in ("ldp_pre", "ldp_post") and regs[2] in (regs[0], regs[1]):
        return False
    if name in ("stp_pre", "stp_post") and regs[2] in (regs[0], regs[1]):
        return False
    return all(r in KINDS[kd] for r, kd in zip(regs, kinds))


rows = []


def add(name, regs, vals):
    kinds, _, _, text = FORMS[name]
    regs = list(regs) + [0] * (3 - len(regs))
    i, j, k = vals
    rows.append((name, regs[0], regs[1], regs[2], i, j, k, text(regs[0], regs[1], regs[2], i, j, k)))


if mode == "table":
    for name in FORMS:
        kinds, edges, _, _ = FORMS[name]
        base = fixed_regs(kinds)
        # Each register in each place.
        for p, kd in enumerate(kinds):
            for r in KINDS[kd]:
                regs = list(base)
                regs[p] = r
                if valid(name, regs):
                    add(name, regs, edges[0])
        # Each edge value with the fixed registers.
        for v in edges[1:]:
            if valid(name, base):
                add(name, base, v)
else:
    rnd = random.Random(total)
    names = sorted(FORMS)
    while len(rows) < total:
        name = rnd.choice(names)
        kinds, _, rval, _ = FORMS[name]
        regs = [rnd.choice(KINDS[kd]) for kd in kinds]
        if not valid(name, regs):
            continue
        add(name, regs, rval(rnd))

with open(work + "/g.s", "w") as s:
    s.write(".text\n")
    for n, row in enumerate(rows):
        s.write("g%d: %s\n" % (n, row[7].replace("NEXT", "g%d" % (n + 1))))
    s.write("g%d: nop\n" % len(rows))
subprocess.run(["zig", "cc", "-target", "aarch64-linux-gnu", "-c", "-x", "assembler", work + "/g.s", "-o", work + "/g.o"], check=True)

data = open(work + "/g.o", "rb").read()
shoff, = struct.unpack_from("<Q", data, 0x28)
shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
secs = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + n * shentsize) for n in range(shnum)]


def secname(sec):
    base = secs[shstrndx][4]
    end = data.index(b"\0", base + sec[0])
    return data[base + sec[0]:end].decode()


text = next(s for s in secs if secname(s) == ".text")
symtab = next(s for s in secs if s[1] == 2)
strtab = secs[symtab[6]]
code = data[text[4]:text[4] + text[5]]
pos = {}
for off in range(symtab[4], symtab[4] + symtab[5], 24):
    name_off, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", data, off)
    end = data.index(b"\0", strtab[4] + name_off)
    name = data[strtab[4] + name_off:end].decode()
    if name.startswith("g") and name[1:].isdigit():
        pos[int(name[1:])] = value

if mode == "random":
    with open(work + "/rows.txt", "w") as out:
        for n, row in enumerate(rows):
            out.write("%s %d %d %d %d %d %d %s\n" % (row[:7] + (code[pos[n]:pos[n + 1]].hex(),)))
    print("random rows: %d" % len(rows), file=sys.stderr)
    sys.exit(0)

out = []
out.append("//! The words of `zig cc` for each instruction form of `a64.zig`.\n")
out.append("//!\n")
out.append("//! tools/jit-asm-golden.sh --arch aarch64 writes this file. Do not\n")
out.append("//! change it by hand.\n")
out.append("//!\n")
out.append("//! SPDX-License-Identifier: BSD-2-Clause\n\n")
out.append("const Row = @import(\"a64.zig\").Row;\n\n")
out.append("pub const rows = [_]Row{\n")
for n, row in enumerate(rows):
    f, a, b, c, i, j, k = row[:7]
    bs = code[pos[n]:pos[n + 1]]
    parts = [".f = .%s" % f]
    if a: parts.append(".a = %d" % a)
    if b: parts.append(".b = %d" % b)
    if c: parts.append(".c = %d" % c)
    if i: parts.append(".i = %d" % i)
    if j: parts.append(".j = %d" % j)
    if k: parts.append(".k = %d" % k)
    parts.append('.bytes = "%s"' % "".join("\\x%02x" % v for v in bs))
    out.append("    .{ %s },\n" % ", ".join(parts))
out.append("};\n")
open(work + "/a64_golden.zig", "w").write("".join(out))
print("rows: %d" % len(rows), file=sys.stderr)
