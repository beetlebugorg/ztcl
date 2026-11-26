# Counts the stubs slots that each package of a corpus of Tcl C packages
# names. Each C file goes through the C preprocessor with USE_TCL_STUBS,
# so each call of the Tcl C API becomes tclStubsPtr->field (or one of the
# other three tables). The scan reads only that preprocessor output.
#   python3 -I corpus.py TCL_SRC PKG_DIR... > counts.tsv
# Output: table, field, the count of packages that name it, the packages.
# SPDX-License-Identifier: BSD-2-Clause
import os, re, subprocess, sys
tcl, pkgs = sys.argv[1], sys.argv[2:]
pat = re.compile(r'\b(tclStubsPtr|tclIntStubsPtr|tclPlatStubsPtr|tclIntPlatStubsPtr)\s*->\s*(\w+)')
tab = {'tclStubsPtr': 'pub', 'tclIntStubsPtr': 'int', 'tclPlatStubsPtr': 'plat', 'tclIntPlatStubsPtr': 'intplat'}
use = {}
for p in pkgs:
    name = os.path.basename(p.rstrip('/'))
    inc = set()
    files = []
    for d, sub, fs in os.walk(p):
        sub[:] = [s for s in sub if s not in ('win', 'macosx', 'mac', 'tests', 'compat')]
        if any(f.endswith('.h') for f in fs): inc.add(d)
        files += [os.path.join(d, f) for f in fs if f.endswith('.c')]
    seen, ok = set(), 0
    for f in sorted(files):
        r = subprocess.run(['cc', '-E', '-P', '-w', '-DUSE_TCL_STUBS', '-DHAVE_UNISTD_H', '-DHAVE_STDINT_H',
            '-DHAVE_LIMITS_H', '-DHAVE_STDLIB_H', '-DHAVE_STRING_H', '-DPACKAGE_NAME="x"', '-DPACKAGE_VERSION="1"',
            '-DVERSION="1"', '-I' + tcl + '/generic', '-I' + tcl + '/unix'] + ['-I' + d for d in sorted(inc)] + [f],
            capture_output=True, text=True, errors='replace')
        if r.returncode: continue
        ok += 1
        for t, fld in pat.findall(r.stdout): seen.add((tab[t], fld))
    print(f'{name}: {ok} of {len(files)} files, {len(seen)} slots', file=sys.stderr)
    for k in seen: use.setdefault(k, []).append(name)
for (t, fld), ps in sorted(use.items(), key=lambda x: (-len(x[1]), x[0])):
    print(f'{t}\t{fld}\t{len(ps)}\t{",".join(sorted(ps))}')
