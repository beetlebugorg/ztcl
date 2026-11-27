#!/usr/bin/env python3
"""Makes the charts of the comparison benchmarks from results.tsv.

Run: python3 -I bench/compare/chart.py [OUT_DIR [RESULTS]]

It writes FAMILY-light.svg and FAMILY-dark.svg for each task family to
OUT_DIR (default: docs/site/bench/). Each chart has one panel for each
task, with one bar for each language. A bar is the median, and the
whisker is the interquartile range. A hollow bar is a noisy value: its
interquartile range is more than 10 % of its median. A panel uses a log
scale only when its largest bar is more than 30 times its smallest, and
its axis says so. It uses only the standard library of Python.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

LANGS = [
    ("ztcl", "ztcl"),
    ("ztcl-nojit", "ztcl no JIT"),
    ("tclsh", "tclsh 8.6"),
    ("python", "Python"),
    ("go", "Go"),
    ("zig", "Zig"),
]

FAMILIES = [
    ("data", "Data formats"),
    ("text", "Text and strings"),
    ("sort", "Sorting"),
    ("net", "Network"),
    ("start", "Startup"),
    ("micro", "Micro benchmarks"),
]

TITLES = {
    "base64": "base64 encode and decode, 16 MB",
    "json": "JSON parse and write again, 25 MB",
    "csv": "CSV to a report, 1,000,000 rows",
    "weblog": "Web log, 200,000 lines: a regex, counts by status and path",
    "wordfreq": "Word frequency, 20 MB of text",
    "strfmt": "Build a string of 1,000,000 formatted lines",
    "template": "Render an HTML table of 100,000 rows",
    "sort_int": "Read and sort 1,000,000 integers",
    "sort_str": "Read and sort 1,000,000 strings",
    "http": "HTTP/1.1 server, one thread, one keep-alive connection",
    "tls": "20 TLS 1.3 handshakes, 1 MiB each",
    "hello": "Hello world: start, print, exit",
    "fib": "Micro: recursive fib(30)",
    "nbody": "Micro: n-body, 50,000 steps",
}

THEMES = {
    "light": {"bg": "#ffffff", "fg": "#1f2328", "muted": "#59636e", "grid": "#d1d9e0",
              "ztcl": "#0969da", "ztcl-nojit": "#54aeff", "tclsh": "#6e7781",
              "python": "#9a6700", "go": "#1a7f37", "zig": "#bc4c00"},
    "dark": {"bg": "#0d1117", "fg": "#f0f6fc", "muted": "#9198a1", "grid": "#3d444d",
             "ztcl": "#4493f8", "ztcl-nojit": "#a5d6ff", "tclsh": "#9198a1",
             "python": "#d29922", "go": "#3fb950", "zig": "#f0883e"},
}

W = 600
MARGIN = 20
PAD_L, PAD_R, PAD_T, PAD_B = 62, 12, 58, 40
PH = 250
GAP = 22
NOISY = 0.10


def load(path):
    rows, env, missing = {}, {}, {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("# missing\t"):
                _, task, lang, why = line.split("\t")
                missing[(task, lang)] = why
            elif line.startswith("# ") and "\t" in line:
                k, v = line[2:].split("\t", 1)
                env[k] = v
            elif line and not line.startswith("#") and not line.startswith("task\t"):
                task, fam, lang, unit, med, q1, q3, lo, hi, n = line.split("\t")
                rows.setdefault(fam, {}).setdefault(task, {})[lang] = {
                    "unit": unit, "med": float(med), "q1": float(q1), "q3": float(q3), "n": int(n)}
    return rows, env, missing


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def fmt(v):
    if v >= 100:
        return "{:,}".format(int(round(v)))
    if v >= 10:
        return "%.1f" % v
    return "%.2f" % v


def nice_max(v):
    e = math.floor(math.log10(v))
    for m in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        top = m * 10 ** e
        if top >= v * 1.08:
            return top
    return 10 ** (e + 1)


def panel(x0, y0, task, data, missing, t):
    out = []
    unit = next(iter(data.values()))["unit"]
    left, top = x0 + PAD_L, y0 + PAD_T
    width, height = W - 2 * MARGIN - PAD_L - PAD_R, PH - PAD_T - PAD_B
    vals = [d["med"] for d in data.values()]
    hi_all = max(max(d["q3"] for d in data.values()), max(vals))
    log = max(vals) / max(min(vals), 1e-9) > 30
    better = "higher is better" if unit == "req/s" else "lower is better"
    axis = ("requests per second" if unit == "req/s" else "wall clock ms") + ", " + better
    if log:
        axis += ", log scale"
    out.append(f'<text x="{x0}" y="{y0 + 18}" font-size="15" font-weight="600" fill="{t["fg"]}">{esc(TITLES.get(task, task))}</text>')
    out.append(f'<text x="{x0}" y="{y0 + 36}" font-size="12" fill="{t["muted"]}">{esc(axis)}</text>')
    if log:
        lo = 10 ** math.floor(math.log10(min(vals)))
        hi = 10 ** math.ceil(math.log10(hi_all * 1.05))
        def py(v):
            return top + height - height * (math.log10(max(v, lo)) - math.log10(lo)) / (math.log10(hi) - math.log10(lo))
        ticks = [lo * 10 ** k for k in range(int(round(math.log10(hi / lo))) + 1)]
    else:
        hi = nice_max(hi_all)
        def py(v):
            return top + height - height * v / hi
        ticks = [hi * k / 4 for k in range(5)]
    for v in ticks:
        y = py(v)
        out.append(f'<line x1="{left}" y1="{y:.1f}" x2="{left + width}" y2="{y:.1f}" stroke="{t["grid"]}" stroke-width="1"/>')
        out.append(f'<text x="{left - 6}" y="{y + 4:.1f}" font-size="11" text-anchor="end" fill="{t["muted"]}">{fmt(v) if v else "0"}</text>')
    n = len(LANGS)
    slot = width / n
    bw = slot * 0.62
    for i, (lang, label) in enumerate(LANGS):
        cx = left + slot * (i + 0.5)
        color = t[lang]
        out.append(f'<text x="{cx:.1f}" y="{top + height + 16}" font-size="12" text-anchor="middle" fill="{t["fg"]}">{esc(label)}</text>')
        d = data.get(lang)
        if d is None:
            if (task, lang) in missing:
                out.append(f'<text x="{cx:.1f}" y="{top + height - 8}" font-size="12" text-anchor="middle" fill="{t["muted"]}">n/a</text>')
            continue
        y = py(d["med"])
        base = top + height
        noisy = (d["q3"] - d["q1"]) / d["med"] > NOISY
        h = max(base - y, 1.5)
        if noisy:
            out.append(f'<rect x="{cx - bw / 2:.1f}" y="{base - h:.1f}" width="{bw:.1f}" height="{h:.1f}" fill="{t["bg"]}" stroke="{color}" stroke-width="2" stroke-dasharray="4 3"/>')
        else:
            out.append(f'<rect x="{cx - bw / 2:.1f}" y="{base - h:.1f}" width="{bw:.1f}" height="{h:.1f}" fill="{color}"/>')
        y1, y3 = py(d["q1"]), py(d["q3"])
        if y1 - y3 > 2:
            out.append(f'<line x1="{cx:.1f}" y1="{y1:.1f}" x2="{cx:.1f}" y2="{y3:.1f}" stroke="{t["fg"]}" stroke-width="1.5"/>')
            for yy in (y1, y3):
                out.append(f'<line x1="{cx - 5:.1f}" y1="{yy:.1f}" x2="{cx + 5:.1f}" y2="{yy:.1f}" stroke="{t["fg"]}" stroke-width="1.5"/>')
        label_y = min(y3, base - h) - 6
        out.append(f'<text x="{cx:.1f}" y="{label_y:.1f}" font-size="12" font-weight="600" text-anchor="middle" fill="{t["fg"]}">{fmt(d["med"])}</text>')
    return out


def svg(theme, fam, title, tasks, env, missing):
    t = THEMES[theme]
    names = [k for k in TITLES if k in tasks]
    H = MARGIN * 2 + 70 + len(names) * (PH + GAP) + 40
    font = "-apple-system, Segoe UI, Helvetica, Arial, sans-serif"
    runs = sorted({d["n"] for tk in tasks.values() for d in tk.values()})
    rr = "%d" % runs[0] if len(runs) == 1 else "%d to %d" % (runs[0], runs[-1])
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="{font}" role="img">',
           f'<title>{esc(title)}: ztcl against Tcl 8.6, Python, Go, and Zig</title>',
           f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>',
           f'<text x="{MARGIN}" y="{MARGIN + 16}" font-size="19" font-weight="700" fill="{t["fg"]}">{esc(title)}</text>',
           f'<text x="{MARGIN}" y="{MARGIN + 36}" font-size="12" fill="{t["muted"]}">The median of {rr} runs of the whole process. The whisker is the interquartile range.</text>',
           f'<text x="{MARGIN}" y="{MARGIN + 52}" font-size="12" fill="{t["muted"]}">{esc(env.get("cpu", ""))}, {esc(env.get("date", "")[:10])}, load {esc(env.get("load_start", "?").split()[0])} at the start.</text>']
    for i, task in enumerate(names):
        out += panel(MARGIN, MARGIN + 70 + i * (PH + GAP), task, tasks[task], missing, t)
    y = H - MARGIN - 22
    out.append(f'<rect x="{MARGIN}" y="{y - 11}" width="14" height="12" fill="{t["bg"]}" stroke="{t["muted"]}" stroke-width="2" stroke-dasharray="4 3"/>')
    out.append(f'<text x="{MARGIN + 20}" y="{y}" font-size="12" fill="{t["muted"]}">A hollow bar is noisy: its interquartile range is more than 10 % of its median.</text>')
    out.append(f'<text x="{MARGIN + 20}" y="{y + 17}" font-size="12" fill="{t["muted"]}">n/a: the language has no program for the task. Data: bench/compare/results.tsv.</text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "site", "bench")
    rows, env, missing = load(sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "results.tsv"))
    os.makedirs(out, exist_ok=True)
    for fam, title in FAMILIES:
        if fam not in rows:
            continue
        for theme in THEMES:
            path = os.path.join(out, f"{fam}-{theme}.svg")
            with open(path, "w") as f:
                f.write(svg(theme, fam, title, rows[fam], env, missing))
            print(path)


if __name__ == "__main__":
    main()
