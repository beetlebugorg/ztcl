# Reads 1M strings and sorts them.
import os, sys
with open(os.path.join(sys.argv[1], "strs.txt")) as f:
    s = sorted(f.read().split())
n = len(s)
print(n, s[0], s[n // 2], s[-1])
