# The JSON benchmark of Python: python3 bench.py LIB MODE FILE.json
# LIB is json, orjson, or simdjson (pysimdjson). Prints the best time of
# one run of MODE, in seconds, or "skip".
# SPDX-License-Identifier: BSD-2-Clause
import json, os, sys, time
lib, mode, file = sys.argv[1:4]
try:
    if lib == "json":
        loads, dumps = json.loads, json.dumps
    elif lib == "orjson":
        import orjson
        loads, dumps = orjson.loads, orjson.dumps
    elif lib == "simdjson":
        import simdjson
        loads, dumps = simdjson.loads, None
    else:
        raise SystemExit("unknown library " + lib)
except ImportError:
    print("skip")
    sys.exit(0)
with open(file, "rb") as f:
    data = f.read()
text = data.decode()
name = os.path.basename(file)[:-5]
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "paths.json")) as f:
    paths = json.load(f)[name]

def get(v, p):
    for k in p:
        v = v[k]
    return v

def walk(v):
    n = 1
    if isinstance(v, list):
        for x in v:
            n += walk(x)
    elif isinstance(v, dict):
        for x in v.values():
            n += walk(x)
    return n

parsed = loads(data)
src = data if lib != "json" else text
sink = 0
def op_parse():
    global sink
    sink += loads(src) is not None
def op_query():
    global sink
    sink += len(str(get(loads(src), paths["query"])))
def op_read3():
    global sink
    d = loads(src)
    for p in paths["read"]:
        sink += len(str(get(d, p)))
def op_walk():
    global sink
    sink += walk(loads(src))
def op_encode():
    global sink
    sink += len(dumps(parsed))
ops = {"parse": op_parse, "query": op_query, "read3": op_read3, "walk": op_walk}
if dumps is not None:
    ops["encode"] = op_encode
if mode not in ops:
    print("skip")
    sys.exit(0)
op = ops[mode]
best, total, n = float("inf"), 0.0, 0
while n < 3 or total < 0.5:
    t = time.perf_counter()
    op()
    s = time.perf_counter() - t
    best = min(best, s)
    total += s
    n += 1
print("%.6g" % best)
