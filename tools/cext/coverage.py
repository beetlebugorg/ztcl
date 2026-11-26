# Writes the coverage table of the stubs tables into docs/dev/cext.md,
# between the lines <!-- coverage --> and <!-- /coverage -->. A slot is
# done when a group file of src/cext/stubs.zig has a pub fn of its name.
#   python3 -I tools/cext/coverage.py          (write the table)
#   python3 -I tools/cext/coverage.py --check  (fail when the page is old)
# SPDX-License-Identifier: BSD-2-Clause
import os, re, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
src = os.path.join(root, 'src', 'cext')
stubs = open(os.path.join(src, 'stubs.zig')).read()
groups = re.search(r'const groups = \.\{(.*?)\};', stubs, re.S).group(1)
done = set()
for f in re.findall(r'@import\("(\w+\.zig)"\)', groups):
    done |= set(re.findall(r'pub fn (\w+)\(', open(os.path.join(src, f)).read()))
slots = open(os.path.join(src, 'slots.zig')).read()
labels = dict(re.findall(r'\.(\w+) => "([^"]+)"', slots))
# The order of the build-out: the use by the corpus of docs/dev/cext.md.
order = ['memory', 'packages', 'objects', 'scripts_and_results', 'channels', 'strings_and_encodings',
         'lists_and_dicts', 'errors', 'interps_and_commands', 'hash_tables', 'variables', 'events',
         'namespaces', 'threads', 'filesystem', 'zlib']
pub = re.findall(r'\.name = "(\w+)", \.area = \.(\w+)', slots)
assert sorted(order) == sorted(labels), 'the order list needs each area'
rows = ['| Area | Slots | Done | Missing |', '|---|---:|---:|---|']
tot = [0, 0]
for a in order:
    names = [n for n, ar in pub if ar == a]
    d = [n for n in names if n in done]
    miss = [n for n in names if n not in done]
    tot[0] += len(names); tot[1] += len(d)
    m = 'none' if not miss else (', '.join(f'`{n}`' for n in miss) if len(miss) <= 6 else f'{len(miss)} slots')
    rows.append(f'| {labels[a]} | {len(names)} | {len(d)} | {m} |')
rows.append(f'| **public, all** | **{tot[0]}** | **{tot[1]}** | {tot[1] * 100 // tot[0]}% |')
def tab(name):
    body = re.search(r'pub const ' + name + r' = \[_\]\?\[\]const u8\{(.*?)\};', slots, re.S).group(1)
    names = re.findall(r'"(\w+)"', body)
    return len(names), len([n for n in names if n in done])
for name, label in [('internal', 'internal'), ('int_plat', 'internal platform'), ('plat', 'platform')]:
    n, d = tab(name)
    rows.append(f'| **{label}** | **{n}** | **{d}** | {d * 100 // n if n else 100}% |')
table = '\n'.join(rows)
page = os.path.join(root, 'docs', 'dev', 'cext.md')
text = open(page).read()
new = re.sub(r'(<!-- coverage -->\n).*?(<!-- /coverage -->)', lambda m: m.group(1) + table + '\n' + m.group(2), text, flags=re.S)
if '--check' in sys.argv:
    if new != text:
        sys.exit('docs/dev/cext.md: the coverage table is old. Run python3 -I tools/cext/coverage.py')
else:
    open(page, 'w').write(new)
print(f'public {tot[1]} of {tot[0]}')
