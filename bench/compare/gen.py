#!/usr/bin/env python3
"""Makes the input files of the comparison benchmarks.

Run: python3 -I bench/compare/gen.py OUT_DIR [SCALE]

SCALE 1 gives the sizes of the published results. A smaller SCALE,
such as 0.01, gives small files for the output check. The files come
from a fixed seed, so each run gives the same bytes.
It uses only the standard library of Python.
"""
import json
import os
import random
import sys


def zipf_weights(n, s=1.1):
    return [1.0 / (k ** s) for k in range(1, n + 1)]


def word(rng, lo, hi):
    return "".join(rng.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(rng.randint(lo, hi)))


def gen_bytes(out, scale):
    rng = random.Random(1)
    with open(os.path.join(out, "bytes.bin"), "wb") as f:
        f.write(rng.randbytes(max(1024, int((16 << 20) * scale))))


def gen_json(out, scale):
    # About 25 MB at scale 1. The strings are ASCII letters, digits,
    # and spaces, so each language writes the same bytes back.
    rng = random.Random(2)
    cities = [word(rng, 4, 10).capitalize() for _ in range(300)]
    tags = [word(rng, 3, 8) for _ in range(50)]
    recs = []
    target = int(25_000_000 * scale)
    size = 0
    i = 0
    while size < target:
        r = {
            "id": i,
            "name": word(rng, 3, 9).capitalize() + " " + word(rng, 4, 11).capitalize(),
            "email": word(rng, 4, 10) + "@" + word(rng, 4, 8) + ".org",
            "active": rng.random() < 0.7,
            "score": rng.randint(-1000, 100000),
            "tags": rng.sample(tags, rng.randint(0, 4)),
            "address": {"city": rng.choice(cities), "zip": "%05d" % rng.randint(0, 99999)},
        }
        recs.append(r)
        size += len(json.dumps(r, indent=2)) + 4
        i += 1
    with open(os.path.join(out, "data.json"), "w") as f:
        json.dump(recs, f, indent=2)
        f.write("\n")


def gen_log(out, scale):
    rng = random.Random(3)
    paths = ["/"] + ["/" + "/".join(word(rng, 3, 8) for _ in range(rng.randint(1, 3))) for _ in range(299)]
    pw = zipf_weights(len(paths))
    statuses = ["200", "304", "404", "301", "500", "403"]
    sw = [80, 8, 6, 3, 2, 1]
    methods = ["GET", "GET", "GET", "POST", "HEAD"]
    agents = ["Mozilla/5.0 (X11; Linux x86_64)", "curl/8.11.0", "Mozilla/5.0 (Macintosh)", "Go-http-client/1.1"]
    n = max(1000, int(200_000 * scale))
    lines = []
    for i in range(n):
        ip = "%d.%d.%d.%d" % (rng.randint(1, 223), rng.randint(0, 255), rng.randint(0, 255), rng.randint(1, 254))
        sec = i * 86400 // n
        ts = "27/Nov/2026:%02d:%02d:%02d +0000" % (sec // 3600, sec // 60 % 60, sec % 60)
        p = rng.choices(paths, pw)[0]
        if rng.random() < 0.1:
            p += "?q=" + word(rng, 2, 6)
        st = rng.choices(statuses, sw)[0]
        size = "-" if st == "304" else str(rng.randint(100, 90000))
        lines.append('%s - - [%s] "%s %s HTTP/1.1" %s %s "-" "%s"\n' % (ip, ts, rng.choice(methods), p, st, size, rng.choice(agents)))
    with open(os.path.join(out, "access.log"), "w") as f:
        f.writelines(lines)


def gen_csv(out, scale):
    rng = random.Random(4)
    regions = ["North", "South", "East", "West", "Central"]
    products = ["Bolt", "Nut", "Washer", "Hinge", "Bracket", "Widget, large", "Widget, small", "Gear", "Spring", "Clamp"]
    n = max(1000, int(1_000_000 * scale))
    with open(os.path.join(out, "sales.csv"), "w") as f:
        f.write("date,region,product,qty,unit_price\n")
        for i in range(n):
            p = rng.choice(products)
            pf = '"%s"' % p if "," in p else p
            f.write("2026-%02d-%02d,%s,%s,%d,%d.%02d\n" % (
                rng.randint(1, 12), rng.randint(1, 28), rng.choice(regions), pf,
                rng.randint(1, 50), rng.randint(0, 199), rng.randint(0, 99)))


def gen_words(out, scale):
    rng = random.Random(5)
    vocab = [word(rng, 2, 10) for _ in range(5000)]
    w = zipf_weights(len(vocab))
    target = int(20_000_000 * scale)
    parts = []
    size = 0
    line = []
    while size < target:
        ws = rng.choices(vocab, w, k=12)
        if rng.random() < 0.2:
            ws[0] = ws[0].capitalize()
        s = " ".join(ws) + rng.choice([".", ",", ";", "!", "?", ""]) + "\n"
        parts.append(s)
        size += len(s)
    with open(os.path.join(out, "words.txt"), "w") as f:
        f.writelines(parts)


def gen_sort(out, scale):
    rng = random.Random(6)
    n = max(1000, int(1_000_000 * scale))
    with open(os.path.join(out, "ints.txt"), "w") as f:
        f.writelines("%d\n" % rng.randint(0, 2**31 - 1) for _ in range(n))
    with open(os.path.join(out, "strs.txt"), "w") as f:
        f.writelines(word(rng, 8, 16) + "\n" for _ in range(n))


def main():
    out = sys.argv[1]
    scale = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    os.makedirs(out, exist_ok=True)
    for g in (gen_bytes, gen_json, gen_log, gen_csv, gen_words, gen_sort):
        g(out, scale)


if __name__ == "__main__":
    main()
