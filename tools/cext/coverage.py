# Writes the coverage table of the stubs tables into docs/dev/cext.md,
# between the lines <!-- coverage --> and <!-- /coverage -->. A slot is
# done in a path when a group file of the path has a pub fn of its name:
# the groups of src/cext/stubs.zig (native) and of
# src/cext/wasm_stubs.zig (WebAssembly).
#   python3 -I tools/cext/coverage.py          (write the table)
#   python3 -I tools/cext/coverage.py --check  (fail when the page is old)
# SPDX-License-Identifier: BSD-2-Clause
import os, re, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
src = os.path.join(root, 'src', 'cext')
def path_done(name):
    text = open(os.path.join(src, name)).read()
    groups = re.search(r'const groups = \.\{(.*?)\};', text, re.S).group(1)
    files = re.findall(r'@import\("(\w+\.zig)"\)', groups)
    if '@This()' in groups:
        files.append(name)
    out = set()
    for f in files:
        out |= set(re.findall(r'pub fn (\w+)\(', open(os.path.join(src, f)).read()))
    return out
done = path_done('stubs.zig')
wdone = path_done('wasm_stubs.zig')
slots = open(os.path.join(src, 'slots.zig')).read()
labels = dict(re.findall(r'\.(\w+) => "([^"]+)"', slots))
# The order of the build-out: the use by the corpus of docs/dev/cext.md.
order = ['memory', 'packages', 'objects', 'scripts_and_results', 'channels', 'strings_and_encodings',
         'lists_and_dicts', 'errors', 'interps_and_commands', 'hash_tables', 'variables', 'events',
         'namespaces', 'threads', 'filesystem', 'zlib']
pub = re.findall(r'\.name = "(\w+)", \.area = \.(\w+)', slots)
assert sorted(order) == sorted(labels), 'the order list needs each area'
rows = ['| Area | Slots | Native | WebAssembly | Missing in native |', '|---|---:|---:|---:|---|']
tot = [0, 0, 0]
for a in order:
    names = [n for n, ar in pub if ar == a]
    d = [n for n in names if n in done]
    miss = [n for n in names if n not in done]
    w = [n for n in names if n in wdone]
    tot[0] += len(names); tot[1] += len(d); tot[2] += len(w)
    m = 'none' if not miss else (', '.join(f'`{n}`' for n in miss) if len(miss) <= 6 else f'{len(miss)} slots')
    rows.append(f'| {labels[a]} | {len(names)} | {len(d)} | {len(w)} | {m} |')
rows.append(f'| **public, all** | **{tot[0]}** | **{tot[1]}** ({tot[1] * 100 // tot[0]}%) | **{tot[2]}** ({tot[2] * 100 // tot[0]}%) | |')
def tab(name):
    body = re.search(r'pub const ' + name + r' = \[_\]\?\[\]const u8\{(.*?)\};', slots, re.S).group(1)
    names = re.findall(r'"(\w+)"', body)
    return len(names), len([n for n in names if n in done]), len([n for n in names if n in wdone])
for name, label in [('internal', 'internal'), ('int_plat', 'internal platform'), ('plat', 'platform')]:
    n, d, w = tab(name)
    rows.append(f'| **{label}** | **{n}** | **{d}** | **{w}** | |')
table = '\n'.join(rows)
page = os.path.join(root, 'docs', 'dev', 'cext.md')
text = open(page).read()
new = re.sub(r'(<!-- coverage -->\n).*?(<!-- /coverage -->)', lambda m: m.group(1) + table + '\n' + m.group(2), text, flags=re.S)
if '--check' in sys.argv:
    if new != text:
        sys.exit('docs/dev/cext.md: the coverage table is old. Run python3 -I tools/cext/coverage.py')
else:
    open(page, 'w').write(new)
print(f'public: native {tot[1]} of {tot[0]}, WebAssembly {tot[2]} of {tot[0]}')
