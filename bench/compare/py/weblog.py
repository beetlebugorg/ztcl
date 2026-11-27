# Parses a web server log with a regular expression and counts the
# requests by status and by path.
import os, re, sys
from collections import Counter
line_re = re.compile(r'^\S+ \S+ \S+ \[[^\]]+\] "\S+ ([^ ?"]+)[^"]*" (\d{3}) ')
by_status, by_path = Counter(), Counter()
with open(os.path.join(sys.argv[1], "access.log")) as f:
    for line in f:
        m = line_re.match(line)
        if m:
            by_status[m.group(2)] += 1
            by_path[m.group(1)] += 1
for s in sorted(by_status):
    print(s, by_status[s])
for p, n in sorted(by_path.items(), key=lambda kv: (-kv[1], kv[0]))[:20]:
    print(n, p)
