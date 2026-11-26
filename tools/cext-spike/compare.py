# Compares the counts of each SQLite test file of two runs: the last
# "N errors out of M tests" line of NAME.log in each folder. Reads the
# names on stdin. Prints each file with other counts, and the totals.
#   python3 -I compare.py OLD_DIR NEW_DIR < LIST
# SPDX-License-Identifier: BSD-2-Clause
import os, re, sys
def counts(d, n):
    try:
        t = open(os.path.join(d, n + '.log'), errors='replace').read()
    except OSError:
        return None
    m = re.findall(r'^(\d+) errors out of (\d+) tests', t, re.M)
    return (int(m[-1][0]), int(m[-1][1])) if m else None
same = other = 0
tot = {'old': [0, 0, 0], 'new': [0, 0, 0]}
for n in sys.stdin.read().split():
    a, b = counts(sys.argv[1], n), counts(sys.argv[2], n)
    for k, c in (('old', a), ('new', b)):
        if c:
            tot[k][0] += 1; tot[k][1] += c[1]; tot[k][2] += c[0]
    if a == b:
        same += 1
    else:
        other += 1
        print(f'{n}\told {a}\tnew {b}')
for k in ('old', 'new'):
    f, t, e = tot[k]
    print(f'# {k}: {f:,} files ran to the end: {t:,} tests, {e:,} errors')
print(f'# {same:,} files have the same counts, {other:,} have other counts')
