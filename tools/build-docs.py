#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Build the ztcl docs site from the Markdown files.

Usage: python3 tools/build-docs.py [output folder]

The landing page is docs/site/index.html. The docs pages come from the
Markdown files, and all pages use docs/site/site.css. The build needs
markdown-it-py (tools/docs-requirements.txt). It stops with an error for a
link to a missing page or a missing anchor, also on the HTML pages.

The playground is docs/site/playground/ with the JS modules of web/ and
the three modules of zig-out/lib/. Run `zig build wasm wasm-threads`
before the build.
"""

import html
import posixpath
import re
import shutil
import sys
from pathlib import Path

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/beetlebugorg/ztcl"
SITE = "https://beetlebug.org/ztcl/"

# Source file, page folder, sidebar group, sidebar title.
PAGES = [
    ("README.md", "overview/", "Start", "Overview"),
    ("docs/language.md", "language/", "Use", "Language and commands"),
    ("docs/shell.md", "shell/", "Use", "Interactive shell"),
    ("docs/embedding.md", "embedding/", "Use", "Embed in Zig"),
    ("docs/webassembly.md", "webassembly/", "Use", "WebAssembly"),
    ("docs/npm.md", "npm/", "Use", "npm package"),
    ("docs/design.md", "design/", "Internals", "Design"),
    ("docs/testing.md", "testing/", "Internals", "Tests and benchmarks"),
    ("docs/compatibility.md", "compatibility/", "Internals", "Compatibility"),
    ("docs/tcl9.md", "tcl9/", "Internals", "Tcl 8.6 and Tcl 9"),
    ("docs/release.md", "release/", "Project", "Releases"),
    ("docs/roadmap.md", "roadmap/", "Project", "Roadmap"),
    ("CHANGELOG.md", "changelog/", "Project", "Changelog"),
    ("CONTRIBUTING.md", "contributing/", "Project", "Contributing"),
    ("SECURITY.md", "security/", "Project", "Security"),
    ("docs/references/tcl.md", "references/tcl/", "Project", "References"),
]
PAGE_OF = {src: page for src, page, _, _ in PAGES}

SITE_DIR = ROOT / "docs" / "site"
PLAYGROUND = SITE_DIR / "playground"
# The files of the playground from web/ and zig-out/lib/.
WEB_FILES = ["ztcl.mjs", "ztcl-worker.mjs", "ztcl-threads.mjs", "ztcl-thread-worker.mjs"]
WASM_FILES = ["ztcl.wasm", "ztcl-threads.wasm", "ztcl-async.wasm"]
# The HTML pages of docs/site and the page folder of each.
HTML_PAGES = [(SITE_DIR / "index.html", ""), (PLAYGROUND / "index.html", "playground/")]


def slug(text):
    text = re.sub(r"[^\w\- ]", "", text.lower()).strip()
    return re.sub(r" +", "-", text)


def inline_text(token):
    return "".join(c.content for c in (token.children or []) if c.type in ("text", "code_inline"))


def rel(from_page, to_page):
    path = posixpath.relpath(to_page or ".", from_page or ".")
    return "./" if path == "." else path.rstrip("/") + "/"


class Build:
    def __init__(self):
        self.md = MarkdownIt("commonmark", {"html": False}).enable("table").enable("strikethrough")
        self.anchors = {}
        self.links = []

    def render(self, src, page):
        tokens = self.md.parse((ROOT / src).read_text(encoding="utf-8"))
        ids, seen, title = set(), {}, None
        for i, token in enumerate(tokens):
            if token.type == "heading_open":
                text = inline_text(tokens[i + 1])
                title = title or text
                base = slug(text)
                n = seen.get(base, 0)
                seen[base] = n + 1
                anchor = base if n == 0 else f"{base}-{n}"
                token.attrSet("id", anchor)
                ids.add(anchor)
            if token.type == "inline":
                for child in token.children or []:
                    if child.type == "link_open":
                        child.attrSet("href", self.link(src, page, child.attrGet("href")))
        self.anchors[page] = ids
        body = self.md.renderer.render(tokens, self.md.options, {})
        body = body.replace("<table>", '<div class="table"><table>').replace("</table>", "</table></div>")
        return title or src, self.alerts(body)

    def link(self, src, page, href):
        if re.match(r"^[a-z][a-z0-9+.-]*:", href) or href.startswith("//"):
            return href
        if href.startswith("#"):
            self.links.append((src, page, href[1:]))
            return href
        path, _, frag = href.partition("#")
        target = posixpath.normpath(posixpath.join(posixpath.dirname(src), path))
        if target in PAGE_OF:
            other = PAGE_OF[target]
            if frag:
                self.links.append((src, other, frag))
            return rel(page, other) + (f"#{frag}" if frag else "")
        if not (ROOT / target).exists():
            raise SystemExit(f"{src}: link to a missing file: {href}")
        kind = "tree" if (ROOT / target).is_dir() else "blob"
        return f"{REPO}/{kind}/main/{target}" + (f"#{frag}" if frag else "")

    @staticmethod
    def alerts(body):
        def replace(match):
            kind, rest = match.group(1).lower(), match.group(2)
            css = "alert warning" if kind in ("warning", "caution", "important") else "alert"
            return f'<div class="{css}"><p>{rest.strip()}</p></div>'
        return re.sub(r"<blockquote>\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*?)</p>\s*</blockquote>", replace, body, flags=re.S)

    def nav(self, page):
        out, group = [], None
        for _, other, section, label in PAGES:
            if section != group:
                out.append(f"<h2>{html.escape(section)}</h2>")
                group = section
            current = ' aria-current="page"' if other == page else ""
            out.append(f'<a class="item" href="{rel(page, other)}"{current}>{html.escape(label)}</a>')
        out.append("<h2>Source</h2>")
        out.append(f'<a class="item" href="{REPO}">GitHub</a>')
        out.append(f'<a class="item" href="{REPO}/releases">Releases</a>')
        return "\n".join(out)

    @staticmethod
    def pager(page):
        pages = [(other, label) for _, other, _, label in PAGES]
        i = next(n for n, (other, _) in enumerate(pages) if other == page)
        out = []
        if i > 0:
            other, label = pages[i - 1]
            out.append(f'<a class="prev" href="{rel(page, other)}"><span>Previous</span>{html.escape(label)}</a>')
        if i + 1 < len(pages):
            other, label = pages[i + 1]
            out.append(f'<a class="next" href="{rel(page, other)}"><span>Next</span>{html.escape(label)}</a>')
        return f'<nav class="pager" aria-label="Pages">{"".join(out)}</nav>'

    def document(self, page, title, body):
        root = rel(page, "")
        name = f"{html.escape(title)} · ztcl"
        desc = "A sandboxed Tcl interpreter in Zig, with a bytecode VM and an optional JIT."
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name}</title><meta name="description" content="{desc}">
<link rel="canonical" href="{SITE}{page}">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}assets/site.css"></head>
<body><a class="skip" href="#content">Skip to the content</a>
<header class="top"><div class="wrap"><a class="logo" href="{root}"><span class="glyph" aria-hidden="true">tc</span>ztcl</a>
<nav class="toplinks" aria-label="Site"><a href="{root}overview/" aria-current="page">Docs</a><a href="{root}playground/">Playground</a><a class="sib" href="https://beetlebug.org/ztk/">ztk</a><a href="{REPO}">GitHub</a></nav></div></header>
<div class="docs"><input class="toc-toggle" type="checkbox" id="toc"><label class="toc-button" for="toc">Contents</label>
<aside class="sidebar"><nav aria-label="Documentation">{self.nav(page)}</nav></aside>
<main class="prose" id="content">{body}{self.pager(page)}</main></div>
<footer class="foot docs-foot"><div class="wrap"><span>ztcl · BSD-2-Clause</span><span class="right"><a href="{root}">Home</a><a href="https://beetlebug.org/ztk/">ztk</a><a href="{REPO}">Source on GitHub</a></span></div></footer>
</body></html>
"""

    def check_html(self, path, at):
        """Checks each relative link of the HTML page `path` in the folder `at`."""
        text = path.read_text(encoding="utf-8")
        name = path.relative_to(ROOT)
        for href in re.findall(r'(?:href|src)="([^"]+)"', text):
            if re.match(r"^[a-z][a-z0-9+.-]*:", href) or href.startswith("//"):
                continue
            target, _, frag = href.partition("#")
            target = target.partition("?")[0]
            full = posixpath.normpath(posixpath.join(at, target or "."))
            full = "" if full == "." else full
            if full.startswith("assets/"):
                if not (SITE_DIR / full[len("assets/"):]).exists():
                    raise SystemExit(f"{name}: link to a missing file: {href}")
                continue
            if full.startswith("playground/") and not href.endswith("/") and target:
                if not (self.playground_file(full[len("playground/"):])).exists():
                    raise SystemExit(f"{name}: link to a missing file: {href}")
                continue
            page = "" if full == "" else full.rstrip("/") + "/"
            if page == at:
                ids = set(re.findall(r'id="([^"]+)"', text))
            elif page in self.anchors:
                ids = self.anchors[page]
            elif page in {p for _, p in HTML_PAGES}:
                ids = set(re.findall(r'id="([^"]+)"', (SITE_DIR / page / "index.html").read_text(encoding="utf-8")))
            else:
                raise SystemExit(f"{name}: link to a missing page: {href}")
            if frag and frag not in ids:
                raise SystemExit(f"{name}: link to a missing anchor: {href}")

    @staticmethod
    def playground_file(name):
        if name in WEB_FILES:
            return ROOT / "web" / name
        if name.endswith(".wasm"):
            return ROOT / "zig-out" / "lib" / name
        return PLAYGROUND / name

    def run(self, out):
        rendered = [(page, *self.render(src, page)) for src, page, _, _ in PAGES]
        for src, page, anchor in self.links:
            if anchor not in self.anchors.get(page, set()):
                raise SystemExit(f"{src}: link to a missing anchor: {page}#{anchor}")
        for name in WASM_FILES:
            if not (ROOT / "zig-out" / "lib" / name).exists():
                raise SystemExit(f"zig-out/lib/{name} is missing: run `zig build wasm wasm-threads` first")
        for path, at in HTML_PAGES:
            self.check_html(path, at)
        if out.exists():
            shutil.rmtree(out)
        for page, title, body in rendered:
            folder = out / page
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "index.html").write_text(self.document(page, title, body), encoding="utf-8")
        shutil.copy(SITE_DIR / "index.html", out / "index.html")
        (out / "assets").mkdir()
        for name in ("site.css", "favicon.svg"):
            shutil.copy(SITE_DIR / name, out / "assets" / name)
        (out / "playground").mkdir()
        for name in [p.name for p in PLAYGROUND.iterdir()] + WEB_FILES + WASM_FILES:
            shutil.copy(self.playground_file(name), out / "playground" / name)
        (out / ".nojekyll").write_text("", encoding="utf-8")
        print(f"wrote {len(rendered) + len(HTML_PAGES)} pages to {out}")


if __name__ == "__main__":
    Build().run(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out" / "docs-site")
