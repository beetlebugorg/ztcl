# Counts the words of a text and writes the 20 most frequent.
import os, re, sys
from collections import Counter
with open(os.path.join(sys.argv[1], "words.txt")) as f:
    words = re.findall(r"[a-z]+", f.read().lower())
counts = Counter(words)
print("tokens", len(words), "distinct", len(counts))
for w, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:20]:
    print(n, w)
