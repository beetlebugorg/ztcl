# Reads the stubs tables of the Tcl 8.6 headers and writes the files of
# the spike of docs/dev/cext-tasks/ into OUT:
#   slots.tsv  each slot: the table, the slot number, the field name
#   tramp.S    x86-64 trampolines: each one counts its slot and jumps on
#   slots.h    the trampoline tables for recstub.c
#   wshim.c    the stubs table of the wasm module: each slot counts its
#              calls in shim_cnt and calls the import tcl.<name>
# The layout comes from the C preprocessor, so the slot numbers are the
# numbers of the Linux build of Tcl 8.6.
#   python3 -I slots.py TCL_SRC OUT
# SPDX-License-Identifier: BSD-2-Clause
import os, re, subprocess, sys
tcl, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
os.chdir(out)
open('hdr.c', 'w').write('#include <tclInt.h>\n#include <tclIntPlatDecls.h>\n#include <tclPlatDecls.h>\n')
subprocess.run(['cc', '-E', '-C', '-P', '-DHAVE_UNISTD_H', '-DHAVE_SYS_PARAM_H', '-DHAVE_STDINT_H',
    '-DHAVE_INTTYPES_H', '-DHAVE_LIMITS_H', '-DHAVE_STDLIB_H', '-DHAVE_STRING_H',
    '-I' + tcl + '/generic', '-I' + tcl + '/unix', 'hdr.c', '-o', 'hdr.i'], check=True)
s = open('hdr.i').read()

# ---- The native recording table ----
tabs=[('TclStubs','pub'),('TclIntStubs','int'),('TclPlatStubs','plat'),('TclIntPlatStubs','intplat')]
asm=['.text']; h=[]; tsv=[]
for t,k in tabs:
    body=re.search(r'typedef struct '+t+r' \{(.*?)\} '+t+';',s,re.S).group(1)
    body=re.sub(r'/\*.*?\*/','',body,flags=re.S)
    stm=[x for x in re.split(r';',body) if x.strip()][2:]
    names=[]
    for x in stm:
        m=re.search(r'\(\*\s*(\w+)\)',x)
        assert m, x
        names.append(m.group(1))
    n=len(names)
    h.append(f'#define N_{k} {n}')
    asm.append(f'.bss\n.balign 8\n.globl rec_cnt_{k}\n.hidden rec_cnt_{k}\nrec_cnt_{k}: .zero {8*n}\n.globl rec_real_{k}\n.hidden rec_real_{k}\nrec_real_{k}: .zero {8*n}\n.text')
    for i,nm in enumerate(names):
        asm.append(f'.globl rec_t_{k}_{i}\n.hidden rec_t_{k}_{i}\nrec_t_{k}_{i}:\n lock incq rec_cnt_{k}+{8*i}(%rip)\n jmp *rec_real_{k}+{8*i}(%rip)')
        tsv.append(f'{k}\t{i}\t{nm}')
    h.append(f'static void *const rec_t_{k}[{n}] = {{'+','.join(f'(void*)rec_t_{k}_{i}' for i in range(n))+'};')
    h.insert(0,'\n'.join(f'extern void rec_t_{k}_{i}(void);' for i in range(n)))
    h.insert(0,f'extern unsigned long rec_cnt_{k}[]; extern void *rec_real_{k}[];')
open('tramp.S','w').write('\n'.join(asm)+'\n.section .note.GNU-stack,"",@progbits\n')
open('slots.h','w').write('\n'.join(h)+'\n')
open('slots.tsv','w').write('\n'.join(tsv)+'\n')
print({k:sum(1 for l in tsv if l.startswith(k+'\t')) for _,k in tabs})

body=re.search(r'typedef struct TclStubs \{(.*?)\} TclStubs;',s,re.S).group(1)
body=re.sub(r'/\*.*?\*/','',body,flags=re.S)
st=[x.strip() for x in body.split(';') if x.strip()][2:]
def split_top(p):
    out=[];d=0;cur=''
    for ch in p:
        if ch in '([': d+=1
        if ch in ')]': d-=1
        if ch==',' and d==0: out.append(cur.strip()); cur=''
        else: cur+=ch
    if cur.strip(): out.append(cur.strip())
    return out
def pname(p):
    m=re.search(r'\(\s*\*\s*(\w+)\s*\)',p)
    if m: return m.group(1)
    p=re.sub(r'\[.*?\]','',p).strip()
    return re.findall(r'\w+',p)[-1]

# ---- The wasm shim ----
o=['#define USE_TCL_STUBS','#include <tcl.h>','#include <stdarg.h>','#include <stdio.h>','#include <stdlib.h>',
   'unsigned shim_cnt[%d];'%len(st),'#define IMP(n) __attribute__((import_module("tcl"),import_name(n)))']
fill=[]
printf={2,578,579,278}
for i,x in enumerate(st):
    x=re.sub(r'__attribute__\s*\(\(.*\)\)\s*$','',x).strip()
    m=re.match(r'(.*?)\(\s*\*\s*(\w+)\s*\)\s*\((.*)\)$',x,re.S)
    ret,name,params=m.group(1).strip(),m.group(2),m.group(3).strip()
    ret=re.sub(r'__attribute__\s*\(\([^)]*\)\)','',ret).strip()
    if name.startswith('reserved'): fill.append('0'); continue
    imp=name[0].upper()+name[1:]
    ps=[] if params=='void' else split_top(params)
    va='...' in ps
    fixed=[p for p in ps if p!='...']
    names=[pname(p) for p in fixed]
    isvoid=ret=='void'
    rv='' if isvoid else 'return '
    if i in printf:
        if va:
            impps=fixed[:-1]+['const char *text']
            o.append(f'IMP("{imp}") {ret} imp_{i}({", ".join(impps)});')
            o.append(f'static {ret} w_{i}({", ".join(fixed)}, ...) {{ shim_cnt[{i}]++; char b[4096]; va_list ap; va_start(ap, {names[-1]}); vsnprintf(b, sizeof b, {names[-1]}, ap); va_end(ap); {rv}imp_{i}({", ".join(names[:-1]+["b"])}); }}')
        else:
            impps=fixed[:-1]+['const char *text']
            o.append(f'IMP("{imp}") {ret} imp_{i}({", ".join(impps[:1]) if False else "const char *text"});')
            o.append(f'static {ret} w_{i}({", ".join(fixed)}) {{ shim_cnt[{i}]++; char b[4096]; vsnprintf(b, sizeof b, format, argList); imp_{i}(b); }}')
    elif va:
        o.append(f'IMP("{imp}") {ret} imp_{i}({", ".join(fixed)}, void *va);')
        o.append(f'static {ret} w_{i}({", ".join(fixed)}, ...) {{ shim_cnt[{i}]++; va_list ap; va_start(ap, {names[-1]}); {"" if isvoid else ret+" r = "}imp_{i}({", ".join(names)}, (void *)ap); va_end(ap); {"" if isvoid else "return r;"} }}')
    else:
        fx=[p.replace('va_list argList','void *argList') for p in fixed]
        o.append(f'IMP("{imp}") {ret} imp_{i}({", ".join(fx) or "void"});')
        cast=['(void *)'+n if 'va_list' in p else n for p,n in zip(fixed,names)]
        o.append(f'static {ret} w_{i}({", ".join(fixed) or "void"}) {{ shim_cnt[{i}]++; {rv}imp_{i}({", ".join(cast)}); }}')
    fill.append(f'(void *)w_{i}')
# Tcl_Panic and Tcl_PanicVA do not return.
o=[l.replace('imp_2(b); }','imp_2(b); abort(); }').replace('imp_278(b); }','imp_278(b); abort(); }') for l in o]
o.append('static void *const slots[%d] = {%s};'%(len(st),','.join(fill)))
o.append(r'''
struct table { int magic; const void *hooks; void *slots[%d]; };
static struct table tab;
const TclStubs *tclStubsPtr;
const TclPlatStubs *tclPlatStubsPtr;
const void *tclIntStubsPtr, *tclIntPlatStubsPtr;
const char *Tcl_InitStubs(Tcl_Interp *interp, const char *version, int exact) {
    tab.magic = TCL_STUB_MAGIC;
    for (int i = 0; i < %d; i++) tab.slots[i] = slots[i];
    tclStubsPtr = (const TclStubs *)&tab;
    return tclStubsPtr->tcl_PkgRequireEx(interp, "Tcl", version, exact, NULL);
}
''' % (len(st),len(st)))
open('wshim.c','w').write('\n'.join(o)+'\n')
