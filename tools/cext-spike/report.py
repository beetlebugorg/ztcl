# Prints the slots that a spike run called: the table, the slot, the
# name, the calls, and the count of test files that called it. Also
# prints the count of test files that ran to the end and their tests.
#   python3 -I report.py SLOTS_TSV OUT_DIR
# SPDX-License-Identifier: BSD-2-Clause
import collections, glob, os, re, sys
names = {}
for line in open(sys.argv[1]):
    k, i, n = line.split()
    names[(k, int(i))] = n
calls, files = collections.Counter(), collections.Counter()
for f in glob.glob(os.path.join(sys.argv[2], '*.slots')):
    for line in open(f):
        k, i, n = line.split()
        calls[(k, int(i))] += int(n)
        files[(k, int(i))] += 1
for key in sorted(calls):
    print(key[0], key[1], names[key], calls[key], files[key], sep='\t')
done = tests = errors = 0
for f in glob.glob(os.path.join(sys.argv[2], '*.log')):
    m = re.findall(r'^(\d+) errors out of (\d+) tests', open(f, errors='replace').read(), re.M)
    if m:
        done += 1
        errors += int(m[-1][0])
        tests += int(m[-1][1])
print(f'# {len(calls)} slots; {done} files ran to the end: {tests} tests, {errors} errors')
