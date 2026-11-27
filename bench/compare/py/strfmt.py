# Builds one string of N formatted lines. Each line has 32 bytes.
import sys
n = int(sys.argv[1])
out = "".join(f"{i:07d}|{'item' + str(i % 1000):<12}|{i * 1.5 / 7:10.3f}\n" for i in range(n))
print(len(out), out[-32:-1])
