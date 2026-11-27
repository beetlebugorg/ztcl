# Reads 1M integers and sorts them.
import os, sys
with open(os.path.join(sys.argv[1], "ints.txt")) as f:
    s = sorted(int(x) for x in f)
n = len(s)
print(n, s[0], s[n // 2], s[-1])
