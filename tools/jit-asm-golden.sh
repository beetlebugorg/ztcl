#!/bin/sh
# Makes the golden table of the x86-64 assembler of the JIT.
#
#   tools/jit-asm-golden.sh            writes src/jit/x64_golden.zig
#   tools/jit-asm-golden.sh --check    fails when the file differs
#   tools/jit-asm-golden.sh --random N checks N random instructions
#
# The tool writes each instruction form of src/jit/x64.zig, with each
# register in each operand place and each displacement and immediate of
# a fixed edge set, to an assembly file. `zig cc -c` assembles it. The
# tool reads the bytes of each row from the symbols of the object file
# and writes a Zig table. The unit test of the assembler encodes each
# row and compares the bytes.
#
# With --random N, the tool makes N random instructions of the same
# forms, with random registers, displacements, and immediates in the
# range of each field. `zig cc -c` assembles them, and
# `zig build jit-fuzz -- --asm FILE` encodes each one with x64.zig and
# compares the bytes. The exit code is 1 when a row differs.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$here/../src/jit/x64_golden.zig"
check=
[ "${1:-}" = --check ] && check=1
work=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-golden.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ "${1:-}" = --random ]; then
    n=${2:?--random needs a count}
    python3 -I - "$work" "$n" <<'PY' || exit 1
import random, struct, subprocess, sys
work, total = sys.argv[1], int(sys.argv[2])
r64 = "rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15".split()
r32 = "eax ecx edx ebx esp ebp esi edi r8d r9d r10d r11d r12d r13d r14d r15d".split()
r8 = "al cl dl bl spl bpl sil dil r8b r9b r10b r11b r12b r13b r14b r15b".split()
xmm = ["xmm%d" % i for i in range(16)]
alus = [("add", 0), ("or", 1), ("and", 4), ("sub", 5), ("xor", 6), ("cmp", 7)]
conds = "o no b ae e ne be a s ns p np l ge le g".split()
sses = [("addsd", 0x58), ("mulsd", 0x59), ("subsd", 0x5C), ("divsd", 0x5E)]
rnd = random.Random(total)

def i32():
    k = rnd.randrange(4)
    if k == 0:
        return rnd.choice([0, 1, -1, 127, 128, -128, -129, 2**31 - 1, -2**31])
    if k == 1:
        return rnd.randrange(-128, 128)
    if k == 2:
        return rnd.randrange(-4096, 4096)
    return rnd.randrange(-2**31, 2**31)

def i8():
    return rnd.randrange(-128, 128)

def mem(b, d):
    return "[%s %s %d]" % (r64[b], "+" if d >= 0 else "-", abs(d))

def reg():
    return rnd.randrange(16)

# Each form: a function of (a, b, d, i, k) to the text, and the kinds of
# its fields: r a register, d a displacement, i an imm32, j an imm8,
# a an ALU, c a condition, s an SSE operation.
forms = {
    "mov_rr64": ("rr", lambda a, b, d, i, k: "mov %s, %s" % (r64[a], r64[b])),
    "mov_rr32": ("rr", lambda a, b, d, i, k: "mov %s, %s" % (r32[a], r32[b])),
    "movzx_rr8": ("rr", lambda a, b, d, i, k: "movzx %s, %s" % (r32[a], r8[b])),
    "test_rr32": ("rr", lambda a, b, d, i, k: "test %s, %s" % (r32[a], r32[b])),
    "imul_rr64": ("rr", lambda a, b, d, i, k: "imul %s, %s" % (r64[a], r64[b])),
    "movapd": ("rr", lambda a, b, d, i, k: "movapd %s, %s" % (xmm[a], xmm[b])),
    "ucomisd": ("rr", lambda a, b, d, i, k: "ucomisd %s, %s" % (xmm[a], xmm[b])),
    "cvtsi2sd": ("rr", lambda a, b, d, i, k: "cvtsi2sd %s, %s" % (xmm[a], r64[b])),
    "movq_xr": ("rr", lambda a, b, d, i, k: "movq %s, %s" % (xmm[a], r64[b])),
    "movq_rx": ("rr", lambda a, b, d, i, k: "movq %s, %s" % (r64[a], xmm[b])),
    "alu_rr64": ("rra", lambda a, b, d, i, k: "%s %s, %s" % (alus[k][0], r64[a], r64[b])),
    "sse": ("rrs", lambda a, b, d, i, k: "%s %s, %s" % (sses[k][0], xmm[a], xmm[b])),
    "mov_rm64": ("rrd", lambda a, b, d, i, k: "mov %s, qword ptr %s" % (r64[a], mem(b, d))),
    "mov_rm32": ("rrd", lambda a, b, d, i, k: "mov %s, dword ptr %s" % (r32[a], mem(b, d))),
    "movzx_rm8": ("rrd", lambda a, b, d, i, k: "movzx %s, byte ptr %s" % (r32[a], mem(b, d))),
    "movsxd_rm": ("rrd", lambda a, b, d, i, k: "movsxd %s, dword ptr %s" % (r64[a], mem(b, d))),
    "lea": ("rrd", lambda a, b, d, i, k: "lea %s, %s" % (r64[a], mem(b, d))),
    "imul_rm64": ("rrd", lambda a, b, d, i, k: "imul %s, qword ptr %s" % (r64[a], mem(b, d))),
    "movsd_xm": ("rrd", lambda a, b, d, i, k: "movsd %s, qword ptr %s" % (xmm[a], mem(b, d))),
    "alu_rm64": ("rrda", lambda a, b, d, i, k: "%s %s, qword ptr %s" % (alus[k][0], r64[a], mem(b, d))),
    "alu_rm32": ("rrda", lambda a, b, d, i, k: "%s %s, dword ptr %s" % (alus[k][0], r32[a], mem(b, d))),
    "mov_mr64": ("rrd", lambda a, b, d, i, k: "mov qword ptr %s, %s" % (mem(a, d), r64[b])),
    "mov_mr32": ("rrd", lambda a, b, d, i, k: "mov dword ptr %s, %s" % (mem(a, d), r32[b])),
    "mov_mr8": ("rrd", lambda a, b, d, i, k: "mov byte ptr %s, %s" % (mem(a, d), r8[b])),
    "movsd_mx": ("rrd", lambda a, b, d, i, k: "movsd qword ptr %s, %s" % (mem(a, d), xmm[b])),
    "mov_mi64": ("rdi", lambda a, b, d, i, k: "mov qword ptr %s, %d" % (mem(a, d), i)),
    "mov_mi32": ("rdi", lambda a, b, d, i, k: "mov dword ptr %s, %d" % (mem(a, d), i)),
    "alu_mi64": ("rdia", lambda a, b, d, i, k: "%s qword ptr %s, %d" % (alus[k][0], mem(a, d), i)),
    "alu_mi32": ("rdia", lambda a, b, d, i, k: "%s dword ptr %s, %d" % (alus[k][0], mem(a, d), i)),
    "mov_mi8": ("rdj", lambda a, b, d, i, k: "mov byte ptr %s, %d" % (mem(a, d), i)),
    "cmp_mi8": ("rdj", lambda a, b, d, i, k: "cmp byte ptr %s, %d" % (mem(a, d), i)),
    "test_mi8": ("rdj", lambda a, b, d, i, k: "test byte ptr %s, %d" % (mem(a, d), i)),
    "inc_m64": ("rd", lambda a, b, d, i, k: "inc qword ptr %s" % mem(a, d)),
    "dec_m64": ("rd", lambda a, b, d, i, k: "dec qword ptr %s" % mem(a, d)),
    "jmp_m": ("rd", lambda a, b, d, i, k: "jmp qword ptr %s" % mem(a, d)),
    "call_m": ("rd", lambda a, b, d, i, k: "call qword ptr %s" % mem(a, d)),
    "mov_ri32": ("ri", lambda a, b, d, i, k: "mov %s, %d" % (r32[a], i)),
    "and_ri32": ("ri", lambda a, b, d, i, k: "and %s, %d" % (r32[a], i)),
    "alu_ri64": ("ria", lambda a, b, d, i, k: "%s %s, %d" % (alus[k][0], r64[a], i)),
    "neg_r64": ("r", lambda a, b, d, i, k: "neg %s" % r64[a]),
    "idiv_r64": ("r", lambda a, b, d, i, k: "idiv %s" % r64[a]),
    "jmp_r64": ("r", lambda a, b, d, i, k: "jmp %s" % r64[a]),
    "call_r64": ("r", lambda a, b, d, i, k: "call %s" % r64[a]),
    "push": ("r", lambda a, b, d, i, k: "push %s" % r64[a]),
    "pop": ("r", lambda a, b, d, i, k: "pop %s" % r64[a]),
    "setcc": ("rc", lambda a, b, d, i, k: "set%s %s" % (conds[k], r8[a])),
    "jcc": ("c", lambda a, b, d, i, k: "{disp32} j%s NEXT" % conds[k]),
    "jmp_rel32": ("", lambda a, b, d, i, k: "{disp32} jmp NEXT"),
    "cqo": ("", lambda a, b, d, i, k: "cqo"),
    "ret": ("", lambda a, b, d, i, k: "ret"),
    "int3": ("", lambda a, b, d, i, k: "int3"),
    "ud2": ("", lambda a, b, d, i, k: "ud2"),
    "nop": ("", lambda a, b, d, i, k: "nop"),
}
names = sorted(forms)
rows = []
for _ in range(total):
    f = rnd.choice(names)
    kinds, text = forms[f]
    a = reg() if "r" in kinds else 0
    b = reg() if kinds.count("r") == 2 else 0
    d = i32() if "d" in kinds else 0
    i = i32() if "i" in kinds else (i8() if "j" in kinds else 0)
    k = 0
    if "a" in kinds:
        k = rnd.randrange(len(alus))
    if "c" in kinds:
        k = rnd.randrange(16)
    if "s" in kinds:
        k = rnd.randrange(len(sses))
    # The row keeps the number of the ALU and SSE operation of x64.zig.
    kf = alus[k][1] if "a" in kinds else (sses[k][1] if "s" in kinds else k)
    rows.append((f, a, b, d, i, kf, text(a, b, d, i, k)))

with open(work + "/r.s", "w") as s:
    s.write(".intel_syntax noprefix\n.text\n")
    for n, row in enumerate(rows):
        s.write("g%d: %s\n" % (n, row[6].replace("NEXT", "g%d" % (n + 1))))
    s.write("g%d: nop\n" % len(rows))
subprocess.run(["zig", "cc", "-c", "-x", "assembler", work + "/r.s", "-o", work + "/r.o"], check=True)
data = open(work + "/r.o", "rb").read()
shoff, = struct.unpack_from("<Q", data, 0x28)
shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
secs = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
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
with open(work + "/rows.txt", "w") as out:
    for n, row in enumerate(rows):
        out.write("%s %d %d %d %d %d %s\n" % (row[0], row[1], row[2], row[3], row[4], row[5], code[pos[n]:pos[n + 1]].hex()))
print("random rows: %d" % len(rows), file=sys.stderr)
PY
    cd "$here/.." && zig build jit-fuzz -- --asm "$work/rows.txt"
    exit $?
fi

python3 -I - "$work" <<'PY'
import struct, subprocess, sys
work = sys.argv[1]
r64 = "rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15".split()
r32 = "eax ecx edx ebx esp ebp esi edi r8d r9d r10d r11d r12d r13d r14d r15d".split()
r8 = "al cl dl bl spl bpl sil dil r8b r9b r10b r11b r12b r13b r14b r15b".split()
xmm = ["xmm%d" % i for i in range(16)]
disps = [0, 1, -1, 127, 128, -128, -129, 0x7fffffff]
imms = disps
imm8s = [0, 1, -1, 127, -128]
alus = [("add", 0), ("or", 1), ("and", 4), ("sub", 5), ("xor", 6), ("cmp", 7)]
conds = "o no b ae e ne be a s ns p np l ge le g".split()
sses = [("addsd", 0x58), ("mulsd", 0x59), ("subsd", 0x5C), ("divsd", 0x5E)]

def mem(b, d):
    return "[%s %s %d]" % (r64[b], "+" if d >= 0 else "-", abs(d))

rows = []  # (fields, text)
def add(f, text, a=0, b=0, d=0, i=0, k=0):
    rows.append(((f, a, b, d, i, k), text))

def pairs():
    # Each register in the first place, then each in the second place.
    for a in range(16):
        yield a, 1
    for b in range(16):
        yield 2, b

def regmem():
    # Each register with a fixed memory operand, then each base with
    # each displacement.
    for a in range(16):
        yield a, 3, 8
    for b in range(16):
        for d in disps:
            yield 1, b, d

def memimm(vals):
    for b in range(16):
        for d in disps:
            yield b, d, vals[1]
    for i in vals:
        yield 3, 0, i

def regimm(vals):
    for a in range(16):
        for i in vals:
            yield a, i

for a, b in pairs():
    add("mov_rr64", "mov %s, %s" % (r64[a], r64[b]), a, b)
    add("mov_rr32", "mov %s, %s" % (r32[a], r32[b]), a, b)
    add("movzx_rr8", "movzx %s, %s" % (r32[a], r8[b]), a, b)
    add("test_rr32", "test %s, %s" % (r32[a], r32[b]), a, b)
    add("imul_rr64", "imul %s, %s" % (r64[a], r64[b]), a, b)
    add("movapd", "movapd %s, %s" % (xmm[a], xmm[b]), a, b)
    add("ucomisd", "ucomisd %s, %s" % (xmm[a], xmm[b]), a, b)
    add("cvtsi2sd", "cvtsi2sd %s, %s" % (xmm[a], r64[b]), a, b)
    add("movq_xr", "movq %s, %s" % (xmm[a], r64[b]), a, b)
    add("movq_rx", "movq %s, %s" % (r64[a], xmm[b]), a, b)
    for name, k in alus:
        add("alu_rr64", "%s %s, %s" % (name, r64[a], r64[b]), a, b, k=k)
    for name, k in sses:
        add("sse", "%s %s, %s" % (name, xmm[a], xmm[b]), a, b, k=k)

for a, b, d in regmem():
    m = mem(b, d)
    add("mov_rm64", "mov %s, qword ptr %s" % (r64[a], m), a, b, d)
    add("mov_rm32", "mov %s, dword ptr %s" % (r32[a], m), a, b, d)
    add("movzx_rm8", "movzx %s, byte ptr %s" % (r32[a], m), a, b, d)
    add("movsxd_rm", "movsxd %s, dword ptr %s" % (r64[a], m), a, b, d)
    add("lea", "lea %s, %s" % (r64[a], m), a, b, d)
    add("imul_rm64", "imul %s, qword ptr %s" % (r64[a], m), a, b, d)
    add("movsd_xm", "movsd %s, qword ptr %s" % (xmm[a], m), a, b, d)
    for name, k in alus:
        add("alu_rm64", "%s %s, qword ptr %s" % (name, r64[a], m), a, b, d, k=k)
        add("alu_rm32", "%s %s, dword ptr %s" % (name, r32[a], m), a, b, d, k=k)
    # The store forms: memory first.
    ma = mem(a, d)
    add("mov_mr64", "mov qword ptr %s, %s" % (ma, r64[b]), a, b, d)
    add("mov_mr32", "mov dword ptr %s, %s" % (ma, r32[b]), a, b, d)
    add("mov_mr8", "mov byte ptr %s, %s" % (ma, r8[b]), a, b, d)
    add("movsd_mx", "movsd qword ptr %s, %s" % (ma, xmm[b]), a, b, d)

for b, d, i in memimm(imms):
    m = mem(b, d)
    add("mov_mi64", "mov qword ptr %s, %d" % (m, i), b, 0, d, i)
    add("mov_mi32", "mov dword ptr %s, %d" % (m, i), b, 0, d, i)
    for name, k in alus:
        add("alu_mi64", "%s qword ptr %s, %d" % (name, m, i), b, 0, d, i, k)
        add("alu_mi32", "%s dword ptr %s, %d" % (name, m, i), b, 0, d, i, k)
for b, d, i in memimm(imm8s):
    m = mem(b, d)
    add("mov_mi8", "mov byte ptr %s, %d" % (m, i), b, 0, d, i)
    add("cmp_mi8", "cmp byte ptr %s, %d" % (m, i), b, 0, d, i)
    add("test_mi8", "test byte ptr %s, %d" % (m, i), b, 0, d, i)
for b in range(16):
    for d in disps:
        m = mem(b, d)
        add("inc_m64", "inc qword ptr %s" % m, b, 0, d)
        add("dec_m64", "dec qword ptr %s" % m, b, 0, d)
        add("jmp_m", "jmp qword ptr %s" % m, b, 0, d)
        add("call_m", "call qword ptr %s" % m, b, 0, d)
for a, i in regimm(imms):
    add("mov_ri32", "mov %s, %d" % (r32[a], i), a, 0, 0, i)
    add("and_ri32", "and %s, %d" % (r32[a], i), a, 0, 0, i)
    for name, k in alus:
        add("alu_ri64", "%s %s, %d" % (name, r64[a], i), a, 0, 0, i, k)
        add("alu_ri32", "%s %s, %d" % (name, r32[a], i), a, 0, 0, i, k)
for a in range(16):
    add("neg_r64", "neg %s" % r64[a], a)
    add("idiv_r64", "idiv %s" % r64[a], a)
    add("jmp_r64", "jmp %s" % r64[a], a)
    add("call_r64", "call %s" % r64[a], a)
    add("push", "push %s" % r64[a], a)
    add("pop", "pop %s" % r64[a], a)
    for k, c in enumerate(conds):
        add("setcc", "set%s %s" % (c, r8[a]), a, k=k)
for k, c in enumerate(conds):
    add("jcc", "{disp32} j%s NEXT" % c, k=k)
add("jmp_rel32", "{disp32} jmp NEXT")
for f in ("cqo", "ret", "int3", "ud2", "nop"):
    add(f, f)

with open(work + "/g.s", "w") as s:
    s.write(".intel_syntax noprefix\n.text\n")
    for n, (_, text) in enumerate(rows):
        s.write("g%d: %s\n" % (n, text.replace("NEXT", "g%d" % (n + 1))))
    s.write("g%d: nop\n" % len(rows))
subprocess.run(["zig", "cc", "-c", "-x", "assembler", work + "/g.s", "-o", work + "/g.o"], check=True)

data = open(work + "/g.o", "rb").read()
shoff, = struct.unpack_from("<Q", data, 0x28)
shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
secs = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
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

out = []
out.append("//! The bytes of `zig cc` for each instruction form of `x64.zig`.\n")
out.append("//!\n")
out.append("//! tools/jit-asm-golden.sh writes this file. Do not change it by hand.\n")
out.append("//!\n")
out.append("//! SPDX-License-Identifier: BSD-2-Clause\n\n")
out.append("const Row = @import(\"x64.zig\").Row;\n\n")
out.append("pub const rows = [_]Row{\n")
for n, (fields, txt) in enumerate(rows):
    f, a, b, d, i, k = fields
    bs = code[pos[n]:pos[n + 1]]
    hexs = "".join("\\x%02x" % c for c in bs)
    parts = [".f = .%s" % f]
    if a: parts.append(".a = %d" % a)
    if b: parts.append(".b = %d" % b)
    if d: parts.append(".d = %d" % d)
    if i: parts.append(".i = %d" % i)
    if k: parts.append(".k = %d" % k)
    parts.append('.bytes = "%s"' % hexs)
    out.append("    .{ %s },\n" % ", ".join(parts))
out.append("};\n")
open(work + "/x64_golden.zig", "w").write("".join(out))
print("rows: %d" % len(rows), file=sys.stderr)
PY

if [ -n "$check" ]; then
    if cmp -s "$work/x64_golden.zig" "$out"; then
        echo "golden table: same"
    else
        echo "golden table: DIFFERS"
        exit 1
    fi
else
    cp "$work/x64_golden.zig" "$out"
    echo "wrote $out"
fi
