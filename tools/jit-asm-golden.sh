#!/bin/sh
# Makes the golden table of the x86-64 assembler of the JIT.
#
#   tools/jit-asm-golden.sh            writes src/jit/x64_golden.zig
#   tools/jit-asm-golden.sh --check    fails when the file differs
#
# The tool writes each instruction form of src/jit/x64.zig, with each
# register in each operand place and each displacement and immediate of
# a fixed edge set, to an assembly file. `zig cc -c` assembles it. The
# tool reads the bytes of each row from the symbols of the object file
# and writes a Zig table. The unit test of the assembler encodes each
# row and compares the bytes.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$here/../src/jit/x64_golden.zig"
check=
[ "${1:-}" = --check ] && check=1
work=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-golden.XXXXXX")
trap 'rm -rf "$work"' EXIT

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
