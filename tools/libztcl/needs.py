# Lists the Tcl functions that each program or shared library imports
# and that libztcl does not have. A slot with no function is "missing":
# the program loads, and the first call aborts with the slot name. A
# name outside the stubs tables and outside the extra functions of
# src/cext/app.zig is "absent": the dynamic loader stops the program.
#   python3 -I tools/libztcl/needs.py FILE...
# The last table ranks the names by the count of files that need them.
# It reads the imports with `nm -D --undefined-only` (Linux).
# SPDX-License-Identifier: BSD-2-Clause
import os, re, subprocess, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
src = os.path.join(root, 'src', 'cext')
text = open(os.path.join(src, 'stubs.zig')).read()
groups = re.search(r'const groups = \.\{(.*?)\};', text, re.S).group(1)
done = set()
for f in re.findall(r'@import\("(\w+\.zig)"\)', groups):
    done |= set(re.findall(r'pub fn (\w+)\(', open(os.path.join(src, f)).read()))
slots = open(os.path.join(src, 'slots.zig')).read()
names = set(re.findall(r'\.name = "(\w+)"', slots)) | set(re.findall(r'^\s+"(\w+)",', slots, re.M))
extra = {'Tcl_Main', 'Tcl_MainEx', 'Tcl_PkgInitStubsCheck', 'Tcl_GetMemoryInfo'}
rank = {}
for path in sys.argv[1:]:
    out = subprocess.run(['nm', '-D', '--undefined-only', path], capture_output=True, text=True, check=True).stdout
    imports = sorted({w.split('@')[0] for w in re.findall(r'\bU (\S+)', out) if re.match(r'_?(Tcl|tcl)', w)})
    missing = [n for n in imports if n in names and n not in done]
    absent = [n for n in imports if n not in names and n not in extra]
    print(f'{os.path.basename(path)}: {len(imports)} Tcl imports, {len(missing)} missing, {len(absent)} absent')
    for n in missing:
        print(f'  missing {n}')
        rank.setdefault(n, set()).add(os.path.basename(path))
    for n in absent:
        print(f'  absent {n}')
        rank.setdefault(n, set()).add(os.path.basename(path))
if len(sys.argv) > 2:
    print('\n| Name | Files |\n|---|---|')
    for n, files in sorted(rank.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f'| `{n}` | {len(files)}: {", ".join(sorted(files))} |')
