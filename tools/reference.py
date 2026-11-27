# SPDX-License-Identifier: BSD-2-Clause
"""The table of the command reference (docs/reference/*.txt).

tools/build-docs.py makes a page of each entry, the index, and api.json
from it. tools/doc-examples.py runs the examples of each entry, and
tools/ref-coverage.py checks that each registered command has an entry.
docs/reference/README.md gives the format.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
FOLDER = ROOT / "docs" / "reference"
# The areas of the index, in order, with their files.
AREAS = [
    ("strings", "Strings"), ("lists", "Lists"), ("dicts", "Dicts and arrays"), ("math", "Math"),
    ("variables", "Variables"), ("control", "Control flow"), ("procs", "Procs and namespaces"),
    ("errors", "Errors"), ("channels", "Files and channels"), ("events", "Events"),
    ("interps", "Interpreters and packages"), ("objects", "Objects"), ("threads", "Threads"),
    ("system", "The system"), ("ztcl", "ztcl modules"),
]
MULTI = {"syn", "sub", "opt", "ex", "err", "names", "diff"}


def parse():
    """Gives the entries of each file in the order of AREAS."""
    entries = []
    for area, _ in AREAS:
        path = FOLDER / f"{area}.txt"
        if not path.exists():
            continue
        entry = None
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith("== "):
                entry = {"name": line[3:].strip(), "area": area, "file": f"docs/reference/{area}.txt", "line": n}
                entries.append(entry)
                continue
            key, sep, value = line.partition(": ")
            if not sep or entry is None:
                raise SystemExit(f"{path}:{n}: a line is not `key: value`: {line}")
            value = value.strip()
            if key in MULTI:
                entry.setdefault(key, []).append(value)
            elif key in ("does", "cap", "cost", "page", "flags"):
                if key in entry:
                    raise SystemExit(f"{path}:{n}: a second `{key}`")
                entry[key] = value
            else:
                raise SystemExit(f"{path}:{n}: an unknown key: {key}")
    seen = set()
    for e in entries:
        if e["name"] in seen:
            raise SystemExit(f"{e['file']}:{e['line']}: a second entry for {e['name']}")
        seen.add(e["name"])
        if "does" not in e:
            raise SystemExit(f"{e['file']}:{e['line']}: {e['name']} has no `does`")
    return entries


def slug(name):
    """The page folder of a command: `::` and characters that a URL does not keep become `-`."""
    return re.sub(r"[^A-Za-z0-9_-]+", "-", name.strip(":")).strip("-") or "op"


def split_sub(text):
    parts = [p.strip() for p in text.split(" | ")]
    return parts[0], " | ".join(parts[1:])


def examples(e):
    """The examples of an entry: (command, expected result or None)."""
    out = []
    for ex in e.get("ex", []):
        m = re.match(r"^(.*?) =>(?: (.*))?$", ex)
        out.append((m.group(1).strip(), m.group(2) or "") if m else (ex.strip(), None))
    for err in e.get("err", []):
        cmd, msg = split_sub(err)
        out.append((cmd, f"error: {msg}"))
    return out


def names(e):
    """Each command name that the entry covers."""
    return [e["name"], *" ".join(e.get("names", [])).split()]


def subcommands(e):
    return [split_sub(s)[0].split()[1] for s in e.get("sub", []) if len(split_sub(s)[0].split()) > 1]


def md_title(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def markdown(e, link, check=False):
    """The Markdown of the page of an entry. link(name) gives the
    relative link to the page of another command. With check, each
    example is a Run link, for tools/doc-examples.py."""
    out = [f"# {e['name']}", "", "```tcl", *e.get("syn", []), "```", "", e["does"], ""]
    if e.get("names"):
        out += ["This page also has " + ", ".join(f"`{n}`" for n in " ".join(e["names"]).split()) + ".", ""]
    if e.get("opt"):
        out += ["## Options", "", "| Option | What it does |", "|---|---|"]
        for o in e["opt"]:
            flag, text = split_sub(o)
            out.append(f"| `{flag}` | {text} |")
        out.append("")
    if e.get("sub"):
        out += ["## Subcommands", "", "| Synopsis | What it does |", "|---|---|"]
        for s in e["sub"]:
            syn, text = split_sub(s)
            out.append(f"| `{syn}` | {text} |")
        out.append("")
    ex = [x for x in examples(e) if not (x[1] or "").startswith("error: ")]
    errs = [x for x in examples(e) if (x[1] or "").startswith("error: ")]
    runnable = check or "cap" not in e
    def item(cmd, want):
        code = "``" + cmd + "``" if "`" in cmd else f"`{cmd}`"
        if not runnable:
            return f"- {code}" + (f" gives `{want}`" if want and not want.startswith("error: ") else "")
        return f"- [{code}](run: {md_title(want)})" if want is not None else f"- [{code}](run:)"
    if ex:
        out += ["## Examples", ""]
        if runnable:
            out += ["A click on an example runs it in the shell of the page.", ""]
        out += [item(c, w) + (f": `{w}`" if w and runnable else "") for c, w in ex] + [""]
    if errs:
        out += ["## Errors", ""]
        for c, w in errs:
            out.append(item(c, w) + f" gives the error `{w[len('error: '):]}`")
        out.append("")
    facts = []
    if "cap" in e:
        facts.append(f"- Capability: `{e['cap']}`. A new interpreter does not have this command. See [Limits and capabilities](../../limits.md).")
    else:
        facts.append("- Capability: none.")
    facts.append(f"- Compute cost: {e.get('cost', 'one compute unit for the call, and more for the commands that it runs.')}")
    if "page" in e:
        facts.append(f"- The full page: [{e['name']}](../../{e['page']}).")
    out += ["## Facts", "", *facts, ""]
    if e.get("diff"):
        out += ["## Differences from Tcl 8.6", "", *[f"- {d}" for d in e["diff"]], ""]
    return "\n".join(out)


def api(entries):
    """api.json: one object for each entry, for agents and tools."""
    rows = []
    for e in entries:
        rows.append({
            "name": e["name"], "area": e["area"], "synopsis": e.get("syn", []), "summary": e["does"],
            "names": names(e),
            "subcommands": [dict(zip(("synopsis", "summary"), split_sub(s))) for s in e.get("sub", [])],
            "options": [dict(zip(("option", "summary"), split_sub(o))) for o in e.get("opt", [])],
            "capability": e.get("cap"), "compute": e.get("cost", "1 for the call"),
            "examples": [{"command": c, "result": w} for c, w in examples(e) if not (w or "").startswith("error: ")],
            "errors": [{"command": c, "message": w[len("error: "):]} for c, w in examples(e) if (w or "").startswith("error: ")],
            "differences": e.get("diff", []),
            "page": f"https://beetlebug.org/ztcl/reference/{slug(e['name'])}/",
        })
    return json.dumps({"version": 1, "commands": rows}, indent=1, ensure_ascii=False)


def first_sentence(text):
    """The first sentence of a description, with no backticks."""
    text = text.replace("`", "")
    m = re.match(r"^(.*?[.!?])(?: |$)", text)
    return m.group(1) if m else text


def shell_table(entries):
    """src/shell/reference.txt: the synopsis, the subcommands, and the
    options of each entry, for Tab and the hint row of the shell."""
    out = ["# Made by `python3 -I tools/reference.py shell-table` from docs/reference/*.txt. Do not edit."]
    for e in entries:
        out.append("== " + " ".join(names(e)))
        out += [f"syn: {s}" for s in e.get("syn", [])]
        for key in ("sub", "opt"):
            for line in e.get(key, []):
                syn, text = split_sub(line)
                out.append(f"{key}: {syn} | {first_sentence(text)}" if text else f"{key}: {syn}")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    import sys
    if sys.argv[1:] != ["shell-table"]:
        raise SystemExit("usage: python3 -I tools/reference.py shell-table")
    sys.stdout.write(shell_table(parse()))
