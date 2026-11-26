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

# Source file, page folder, sidebar group, sidebar title. Plans, task
# lists, and reports are in docs/dev/ and are not part of the site.
PAGES = [
    ("README.md", "overview/", "Start", "Overview"),
    ("docs/install.md", "install/", "Start", "Install"),
    ("docs/quickstart.md", "quickstart/", "Start", "Quick start"),
    ("docs/language.md", "language/", "Guide", "Language"),
    ("docs/shell.md", "shell/", "Guide", "The shell"),
    ("docs/limits.md", "limits/", "Guide", "Limits and capabilities"),
    ("docs/threads.md", "threads/", "Guide", "Threads"),
    ("docs/processes.md", "processes/", "Guide", "Run programs"),
    ("docs/jit.md", "jit/", "Guide", "The JIT"),
    ("docs/build.md", "build/", "Guide", "Build a program"),
    ("docs/modules/json.md", "modules/json/", "Guide", "Module ztcl::json"),
    ("docs/modules/open.md", "modules/open/", "Guide", "Module ztcl::open"),
    ("docs/modules/pty.md", "modules/pty/", "Guide", "Module ztcl::pty"),
    ("docs/modules/win.md", "modules/win/", "Guide", "Module ztcl::win"),
    ("docs/embedding.md", "embedding/", "Embed", "Embed in Zig"),
    ("docs/webassembly.md", "webassembly/", "Embed", "WebAssembly"),
    ("docs/performance.md", "performance/", "Project", "Performance"),
    ("docs/faq.md", "faq/", "Project", "FAQ"),
    ("CHANGELOG.md", "changelog/", "Project", "Changelog"),
    ("CONTRIBUTING.md", "contributing/", "Project", "Contributing"),
    ("SECURITY.md", "security/", "Project", "Security"),
    ("docs/references/tcl.md", "references/tcl/", "Project", "References"),
]
# Old page folders and their new place.
REDIRECTS = {
    "npm/": "install/#npm",
    "design/": f"{REPO}/blob/main/docs/dev/design.md",
    "testing/": "performance/",
    "compatibility/": "language/",
    "tcl9/": "language/#tcl-9",
    "release/": "changelog/",
    "roadmap/": "faq/#where-is-the-roadmap",
}
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
        plain = self.md.renderer.rules.get("fence")

        def fence(tokens, idx, options, env):
            t = tokens[idx]
            if not t.meta.get("live"):
                return plain(tokens, idx, options, env)
            # A live example (docs/site/live.js): an editor and its output.
            return (f'<figure class="live-demo" id="{t.meta["id"]}"><div class="ld-code"><pre><code class="language-tcl">'
                    f'{html.escape(t.content)}</code></pre></div><pre class="ld-out" aria-live="polite"></pre>'
                    f'<figcaption class="ld-bar"><span class="ld-tag">Live</span></figcaption></figure>\n')
        self.md.renderer.rules["fence"] = fence
        self.anchors = {}
        self.links = []

    @staticmethod
    def live_blocks(src, tokens):
        """Marks each `tcl` block after a line `<!-- live -->` as a live
        example, and drops the line."""
        out, i, count = [], 0, 0
        while i < len(tokens):
            t = tokens[i]
            if t.type == "paragraph_open" and i + 1 < len(tokens) and tokens[i + 1].content.strip() == "<!-- live -->":
                fence = tokens[i + 3] if i + 3 < len(tokens) else None
                if fence is None or fence.type != "fence" or fence.info.strip() != "tcl":
                    raise SystemExit(f"{src}: a live marker is not just before a tcl block")
                count += 1
                fence.meta = {"live": True, "id": f"live-{count}"}
                out.append(fence)
                i += 4
                continue
            out.append(t)
            i += 1
        return out

    def render(self, src, page):
        tokens = self.live_blocks(src, self.md.parse((ROOT / src).read_text(encoding="utf-8")))
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
        script = f'\n<script type="module" src="{root}assets/live.js"></script>' if 'class="live-demo"' in body else ""
        desc = "A sandboxed Tcl interpreter in Zig, with a bytecode VM and an optional JIT."
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name}</title><meta name="description" content="{desc}">
<link rel="canonical" href="{SITE}{page}">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}assets/site.css">{script}</head>
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
            if full in ("llms.txt", "llms-full.txt"):
                # The files for agents (agents()).
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

    @staticmethod
    def agents(out):
        """The files for agents (https://llmstxt.org): llms.txt lists the
        pages, and llms-full.txt has the Markdown of each page."""
        intro = ("# ztcl\n\n> A Tcl interpreter in Zig with a bytecode VM and a JIT. A new interpreter has no host "
                 "access: the host turns on each capability by name, and sets a compute limit and a memory limit "
                 "before it runs a script that it did not write. It runs as a CLI, as a library in Zig, and in a "
                 "browser as WebAssembly.\n\n")
        lines, full, group = [intro], [intro], None
        for src, page, section, label in PAGES:
            if section != group:
                lines.append(f"\n## {section}\n\n")
                group = section
            lines.append(f"- [{label}]({SITE}{page})\n")
            full.append(f"\n\n<!-- {SITE}{page} -->\n\n" + (ROOT / src).read_text(encoding="utf-8"))
        lines.append(f"\n## For agents\n\n- [Full text]({SITE}llms-full.txt): the Markdown of each page above.\n"
                     f"- [ztk](https://beetlebug.org/ztk/llms.txt): Tk on ztcl, for GUI apps.\n")
        (out / "llms.txt").write_text("".join(lines), encoding="utf-8")
        (out / "llms-full.txt").write_text("".join(full), encoding="utf-8")

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
        for name in ("site.css", "favicon.svg", "live.js"):
            shutil.copy(SITE_DIR / name, out / "assets" / name)
        (out / "playground").mkdir()
        for name in [p.name for p in PLAYGROUND.iterdir()] + WEB_FILES + WASM_FILES:
            shutil.copy(self.playground_file(name), out / "playground" / name)
        for old, new in REDIRECTS.items():
            if not new.startswith("https:"):
                page, _, frag = new.partition("#")
                if page not in self.anchors or (frag and frag not in self.anchors[page]):
                    raise SystemExit(f"redirect {old}: link to a missing page or anchor: {new}")
                new = rel(old, page) + (f"#{frag}" if frag else "")
            (out / old).mkdir(parents=True, exist_ok=True)
            target = html.escape(new)
            (out / old / "index.html").write_text(
                f'<!doctype html><meta charset="utf-8"><title>Moved</title>'
                f'<meta http-equiv="refresh" content="0; url={target}">'
                f'<link rel="canonical" href="{target}"><a href="{target}">This page moved.</a>\n',
                encoding="utf-8")
        self.agents(out)
        (out / ".nojekyll").write_text("", encoding="utf-8")
        print(f"wrote {len(rendered) + len(HTML_PAGES)} pages to {out}")


if __name__ == "__main__":
    Build().run(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out" / "docs-site")
