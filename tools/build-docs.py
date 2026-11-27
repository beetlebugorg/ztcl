#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Build the ztcl docs site from the Markdown files.

Usage: python3 tools/build-docs.py [output folder]

The landing page is docs/site/index.html. The docs pages come from the
Markdown files, and all pages use docs/site/site.css. The build needs
markdown-it-py (tools/docs-requirements.txt). It stops with an error for a
link to a missing page or a missing anchor, also on the HTML pages.

The playground is docs/site/playground/ with the JS modules of web/ and
the four modules of zig-out/lib/. The shell of the landing page and of
docs/site/try/ (docs/site/shell.js) loads ztcl-shell.wasm from there.
Run `zig build wasm wasm-threads wasm-shell wasm-host` before the build.
"""

import html
import json
import posixpath
import re
import shutil
import sys
from pathlib import Path

from markdown_it import MarkdownIt

sys.path.insert(0, str(Path(__file__).resolve().parent))
import reference  # noqa: E402  (tools/reference.py: the table of the command reference)

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/beetlebugorg/ztcl"
SITE = "https://beetlebug.org/ztcl/"

# The lessons of the Learn course (docs/dev/learn.md): docs/learn/NN-slug.md
# is the page learn/NN-slug/, and the first line of the file is its title.
# A lesson of the advanced track has a number from 90.
LEARN = ROOT / "docs" / "learn"
LESSONS, ADVANCED = [], []
for _path in sorted(LEARN.glob("[0-9][0-9]-*.md")):
    _n = int(_path.name[:2])
    _title = _path.read_text(encoding="utf-8").partition("\n")[0].lstrip("# ").strip()
    if _n >= 90:
        ADVANCED.append((f"docs/learn/{_path.name}", f"learn/{_path.stem}/", "Learn: advanced", _title))
    else:
        LESSONS.append((f"docs/learn/{_path.name}", f"learn/{_path.stem}/", "Learn", f"{_n}. {_title}"))
FIRST_LESSON = LESSONS[0][1]
# The old anchors of the one long page learn/ and their lessons.
LEARN_ANCHORS = {
    "words-and-substitution": "01", "variables-and-numbers": "02", "lists": "03", "dicts": "03",
    "control-flow": "04", "procs": "04", "strings": "05", "errors": "06", "namespaces": "07",
    "files": "08", "events": "09", "coroutines": "09", "objects": "10", "lambdas": "04",
    "mistakes-to-avoid": "04",
}

# Source file, page folder, sidebar group, sidebar title. Plans, task
# lists, and reports are in docs/dev/ and are not part of the site.
PAGES = [
    ("README.md", "overview/", "Start", "Overview"),
    ("docs/install.md", "install/", "Start", "Install"),
    ("docs/quickstart.md", "quickstart/", "Start", "Quick start"),
    *LESSONS,
    ("docs/language.md", "language/", "Learn", "Coming from tclsh"),
    ("docs/tcl91.md", "tcl91/", "Learn", "Tcl 9.1"),
    *ADVANCED,
    ("docs/shell.md", "shell/", "Guide", "The shell"),
    ("docs/limits.md", "limits/", "Guide", "Limits and capabilities"),
    ("docs/threads.md", "threads/", "Guide", "Threads"),
    ("docs/isolation.md", "isolation/", "Guide", "Isolated threads"),
    ("docs/metering.md", "metering/", "Guide", "Metering"),
    ("docs/agents.md", "agents/", "Guide", "Sandboxed agents"),
    ("docs/vm.md", "vm/", "Guide", "Linux guests"),
    ("docs/processes.md", "processes/", "Guide", "Run programs"),
    ("docs/jit.md", "jit/", "Guide", "The JIT"),
    ("docs/build.md", "build/", "Guide", "Build a program"),
    ("docs/strip.md", "strip/", "Guide", "Strip a program"),
    ("docs/debugging.md", "debugging/", "Guide", "Debugging"),
    ("docs/targets.md", "targets/", "Guide", "Targets"),
    ("docs/reference/README.md", "reference/", "Reference", "Commands"),
    ("docs/modules/README.md", "modules/", "Modules", "All modules"),
    ("docs/modules/json.md", "modules/json/", "Modules", "ztcl::json"),
    ("docs/modules/vt.md", "modules/vt/", "Modules", "ztcl::vt"),
    ("docs/modules/wasm.md", "modules/wasm/", "Modules", "ztcl::wasm"),
    ("docs/modules/probe.md", "modules/probe/", "Modules", "ztcl::probe"),
    ("docs/modules/disasm.md", "modules/disasm/", "Modules", "ztcl::disasm"),
    ("docs/modules/pty.md", "modules/pty/", "Modules", "ztcl::pty"),
    ("docs/modules/watch.md", "modules/watch/", "Modules", "ztcl::watch"),
    ("docs/modules/tls.md", "modules/tls/", "Modules", "ztcl::tls"),
    ("docs/modules/open.md", "modules/open/", "Modules", "ztcl::open"),
    ("docs/modules/notify.md", "modules/notify/", "Modules", "ztcl::notify"),
    ("docs/modules/meter.md", "modules/meter/", "Modules", "ztcl::meter"),
    ("docs/modules/agent.md", "modules/agent/", "Modules", "ztcl::agent"),
    ("docs/modules/vm.md", "modules/vm/", "Modules", "ztcl::vm"),
    ("docs/modules/win.md", "modules/win/", "Modules", "ztcl::win"),
    ("docs/modules/mac.md", "modules/mac/", "Modules", "ztcl::mac"),
    ("docs/modules/web.md", "modules/web/", "Modules", "web"),
    ("docs/web/README.md", "web/", "Web APIs", "All Web APIs"),
    ("docs/web/serial.md", "web/serial/", "Web APIs", "Serial ports"),
    ("docs/web/usb.md", "web/usb/", "Web APIs", "USB devices"),
    ("docs/web/bluetooth.md", "web/bluetooth/", "Web APIs", "Bluetooth devices"),
    ("docs/web/hid.md", "web/hid/", "Web APIs", "HID devices"),
    ("docs/web/midi.md", "web/midi/", "Web APIs", "MIDI ports"),
    ("docs/web/gamepad.md", "web/gamepad/", "Web APIs", "Gamepads"),
    ("docs/embedding.md", "embedding/", "Embed", "Embed in Zig"),
    ("docs/webassembly.md", "webassembly/", "Embed", "WebAssembly"),
    ("docs/dom.md", "dom/", "Embed", "Tcl in a web page"),
    ("docs/performance.md", "performance/", "Project", "Performance"),
    ("docs/tls.md", "tls/", "Project", "TLS 1.3"),
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
WEB_FILES = ["ztcl.mjs", "ztcl-worker.mjs", "ztcl-threads.mjs", "ztcl-thread-worker.mjs", "ztcl-shell.mjs", "ztcl-web.mjs", "webidl-table.mjs"]
WASM_FILES = ["ztcl.wasm", "ztcl-threads.wasm", "ztcl-async.wasm", "ztcl-shell.wasm", "ztcl-host.wasm"]
# The HTML pages of docs/site and the page folder of each.
HTML_PAGES = [(SITE_DIR / "index.html", ""), (PLAYGROUND / "index.html", "playground/"), (SITE_DIR / "try" / "index.html", "try/")]


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
            if t.meta.get("shell"):
                return self.shell_html(t.content)
            if t.meta.get("define"):
                code = html.escape(t.content)
                return (f'<figure class="zdefine"><pre><code class="language-tcl">{code}</code></pre>'
                        f'<figcaption><button type="button" class="zrun-box" data-cmd="{html.escape(t.content.rstrip(), quote=True)}">'
                        f'Run in the shell</button></figcaption></figure>\n')
            if t.meta.get("helper"):
                return self.helper_html(t.meta["helper"], t.meta["id"], t.content)
            if t.meta.get("file"):
                name = html.escape(t.meta["file"])
                return f'<figure class="zfile"><figcaption><code>{name}</code></figcaption>{plain(tokens, idx, options, env)}</figure>\n'
            if not t.meta.get("live"):
                return plain(tokens, idx, options, env)
            # A live example (docs/site/live.js): an editor and its output.
            # The output of the page shows until the example runs. An
            # example of ztcl::vt also gets a view of the screen.
            term = ' data-term="1"' if "ztcl::vt" in t.content else ""
            # A DOM example runs in the page with ztcl-host.wasm, and its
            # HTML is the stage: the root element of `dom`.
            stage = f'<div class="ld-stage">{t.meta["dom"]}</div>' if "dom" in t.meta else ""
            dom = ' data-dom="1"' if stage else ""
            return (f'<figure class="live-demo" id="{t.meta["id"]}"{term}{dom}><div class="ld-code"><pre><code class="language-tcl">'
                    f'{html.escape(t.content)}</code></pre></div>{stage}<pre class="ld-out" aria-live="polite">{html.escape(t.meta.get("out", ""))}</pre>'
                    f'<figcaption class="ld-bar"><span class="ld-tag">Live</span></figcaption></figure>\n')
        self.md.renderer.rules["fence"] = fence
        self.anchors = {}
        # Each command name of the reference and its page, for the links
        # of the lessons.
        self.ref_names = {n: f"reference/{reference.slug(e['name'])}/" for e in reference.parse() for n in reference.names(e) if "::" not in n or n.startswith("ztcl::")}
        self.checkpoints = {}
        self.files_of = {}
        self.links = []

    def live_blocks(self, src, tokens):
        """Reads the comment lines before a code block and drops them.

        `<!-- live -->` and `<!-- run -->` make a `tcl` block a live example.
        tools/doc-examples.py runs each `<!-- run -->` block, and a `text`
        block after it is its output: the page shows that output until the
        example runs in the page. `<!-- run: FLAGS -->` needs capabilities
        of the runner, so the page shows its blocks as plain code.

        `<!-- shell -->` puts the shell of the page (docs/site/shell.js) in
        place of a `tcl` block. The block is the state of the page: the
        shell runs it first, and the page shows it below the shell.
        `<!-- file: NAME -->` makes a code block a read-only file of that
        shell. `<!-- helper: TITLE -->` makes a `tcl` block a helper
        (docs/site/helper.js): a ztk app that builds a command and gives
        it to the shell. Each other comment line stops the build, so that
        no comment shows as text on a page."""
        out, i, count = [], 0, 0
        self.page_files, self.page_shell, helpers, needs_shell = {}, False, 0, False
        self.checkpoint = None
        while i < len(tokens):
            t = tokens[i]
            text = tokens[i + 1].content.strip() if t.type == "paragraph_open" and i + 1 < len(tokens) else ""
            if text.startswith("<!--"):
                fence = tokens[i + 3] if i + 3 < len(tokens) else None
                if fence is None or fence.type != "fence":
                    raise SystemExit(f"{src}: a comment line is not just before a code block: {text}")
                if text.startswith("<!-- file: ") and text.endswith(" -->"):
                    name = text[len("<!-- file: "):-4].strip()
                    self.page_files[name] = fence.content
                    fence.meta = {"file": name}
                    out.append(fence)
                    i += 4
                    continue
                if fence.info.strip() != "tcl":
                    raise SystemExit(f"{src}: a comment line is not just before a tcl block: {text}")
                if text.startswith("<!-- run:"):
                    i += 3
                    continue
                if text == "<!-- checkpoint -->" or text.startswith("<!-- checkpoint: "):
                    # The state of a lesson at its start: the course shell
                    # runs it first, and the page shows it folded at the end.
                    self.checkpoint = fence.content
                    i += 4
                    continue
                if text == "<!-- define -->":
                    # The code box of a lesson, with a button that runs it
                    # in the course shell.
                    fence.meta = {"define": True}
                    out.append(fence)
                    i += 4
                    continue
                if text == "<!-- shell -->":
                    if self.page_shell:
                        raise SystemExit(f"{src}: a page has one shell")
                    self.page_shell = True
                    fence.meta = {"shell": True}
                    out.append(fence)
                    i += 4
                    continue
                if text.startswith("<!-- helper: ") and text.endswith(" -->"):
                    helpers += 1
                    fence.meta = {"helper": text[len("<!-- helper: "):-4].strip(), "id": f"helper-{helpers}"}
                    if not re.search(r"^# shell: none$", fence.content, re.M):
                        needs_shell = True
                    out.append(fence)
                    i += 4
                    continue
                if text == "<!-- dom -->":
                    # A live example of `dom`: a tcl block, then an html
                    # block with the elements of the stage.
                    stage = tokens[i + 4] if i + 4 < len(tokens) else None
                    if stage is None or stage.type != "fence" or stage.info.strip() != "html":
                        raise SystemExit(f"{src}: <!-- dom --> needs an html block after the tcl block")
                    count += 1
                    fence.meta = {"live": True, "id": f"live-{count}", "dom": stage.content}
                    out.append(fence)
                    i += 5
                    continue
                if text not in ("<!-- live -->", "<!-- run -->"):
                    raise SystemExit(f"{src}: an unknown comment line: {text}")
                count += 1
                fence.meta = {"live": True, "id": f"live-{count}"}
                out.append(fence)
                i += 4
                after = tokens[i] if i < len(tokens) else None
                if text == "<!-- run -->" and after is not None and after.type == "fence" and after.info.strip() == "text":
                    fence.meta["out"] = after.content
                    i += 1
                continue
            out.append(t)
            i += 1
        if needs_shell and not self.page_shell and self.checkpoint is None:
            raise SystemExit(f"{src}: a page with a helper needs a shell (<!-- shell -->)")
        return out

    def shell_html(self, setup):
        """The shell of a docs page, with the state of the page (setup)
        and its files. The poster is the first screen as text."""
        banner = "ztcl in your browser. No network or clock.\\nThe state of this page is loaded. Each command can use 10,000,000 compute units."
        files = "".join(f" {html.escape(n)}" for n in self.page_files)
        if files:
            banner += f"\\nRead-only files:{files}"
        poster = html.escape(banner.replace("\\n", "\n"))
        data = json.dumps({"setup": setup, "files": self.page_files}).replace("</", "<\\/")
        return f"""<div class="zshell zpage-shell" id="shell" style="--rows: 12" data-rows="12" data-label="ztcl shell of this page. Type a Tcl command. Tab completes." data-banner="{html.escape(banner)}">
  <div class="bar"><i></i><i></i><i></i><span>ztcl shell</span><button type="button" class="zshell-dock" aria-pressed="false" hidden>Keep in view</button><label><input class="zshell-vi" type="checkbox" disabled> vim keys</label></div>
<pre class="zshell-poster" aria-hidden="true">{poster}
<span class="p">%</span> </pre>
  <div class="zshell-foot">
    <span class="zshell-hint" id="shell-hint"><kbd>Tab</kbd> completes. <kbd>Up</kbd> is history. <kbd>Ctrl-X</kbd> <kbd>Ctrl-E</kbd> edits. <kbd>Alt-I</kbd> inspects the last result. <kbd>Esc</kbd> <kbd>Tab</kbd> leaves.</span>
    <span class="zshell-meter"><span>Compute limit: 10,000,000 compute units for each command</span><progress value="0" max="10000000" aria-label="Compute units of the last command"></progress></span>
  </div>
  <noscript><p class="zshell-foot">The shell needs JavaScript and WebAssembly.</p></noscript>
  <script type="application/json" class="zpage-state">{data}</script>
</div>
<details class="zsetup"><summary>The state of the shell</summary><pre><code class="language-tcl">{html.escape(setup)}</code></pre></details>
"""

    @staticmethod
    def course_html(page, setup, files):
        """The shell of the Learn course: a panel at the right of a wide
        window and a sheet at the bottom of a narrow one. It is fixed in
        the window, so that a Run link never scrolls the page. shell.js
        runs the checkpoint of the lesson (setup), then the commands that
        the reader ran on this lesson in this tab."""
        banner = "ztcl in your browser. No network or clock.\\nThe state of this page is loaded.\\nEach command can use 10,000,000 compute units."
        if files:
            banner += "\\nRead-only files:" + "".join(f" {n}" for n in files)
        data = json.dumps({"setup": setup or "", "files": files}).replace("</", "<\\/")
        lesson = page.strip("/").replace("/", ":")
        return f"""<aside class="zcourse-dock" aria-label="The shell of the course">
<div class="zshell zpage-shell zcourse" id="shell" data-rows="12" data-lesson="{lesson}" data-label="ztcl shell of this page. Type a Tcl command. Tab completes." data-banner="{html.escape(banner)}">
  <div class="bar"><i></i><i></i><i></i><span>ztcl shell</span><button type="button" class="zcourse-again">Start again</button><button type="button" class="zcourse-size" aria-expanded="true">Make small</button></div>
<pre class="zshell-poster" aria-hidden="true">{html.escape(banner.replace("\\n", chr(10)))}
<span class="p">%</span> </pre>
  <div class="zshell-foot">
    <span class="zshell-hint" id="shell-hint">A <kbd>Run</kbd> link on this page runs its command here. <kbd>Tab</kbd> completes. <kbd>Up</kbd> is history. <kbd>Esc</kbd> <kbd>Tab</kbd> leaves.</span>
    <span class="zshell-meter"><span>Compute limit: 10,000,000 compute units for each command</span><progress value="0" max="10000000" aria-label="Compute units of the last command"></progress></span>
  </div>
  <noscript><p class="zshell-foot">The shell needs JavaScript and WebAssembly.</p></noscript>
  <script type="application/json" class="zpage-state">{data}</script>
</div></aside>
"""

    @staticmethod
    def helper_html(title, hid, script):
        """A helper: a ztk app in a box of a fixed height, so that the page
        does not move when it starts. The code shows below it."""
        lines = script.count("\n")
        m = re.search(r"^# height: (\d+)$", script, re.M)
        height = int(m.group(1)) if m else 240
        # The comment is `<!-- helper: TITLE | CAPTION -->`. The title
        # names the tool, and the caption says what to do with it.
        title, _, caption = title.partition("|")
        t = html.escape(title.strip())
        c = html.escape(caption.strip())
        # A helper with the line `# shell: none` runs no command. It shows
        # the shape of the commands of a module that the page cannot run.
        alone = re.search(r"^# shell: none$", script, re.M)
        hint = ("Its commands do not run in this page." if alone else
                "Put in the shell puts the command on the line of the shell of this page.")
        # A helper with the line `# toy` is an app of a lesson, with no
        # command for the shell.
        toy = re.search(r"^# toy$", script, re.M)
        tag, what = ("Toy", "this window") if toy else ("Tool", "this tool")
        if toy:
            hint = ""
        return (f'<figure class="zhelper" id="{hid}" aria-label="Helper: {t}"{' data-shell="none"' if alone else ''}>'
                f'<figcaption class="zhelper-bar"><span class="zhelper-tag">{tag}</span><span class="zhelper-title">{t}</span>'
                f'{f"<span class=\"zhelper-caption\">{c}</span>" if c else ""}{f'<span class="zhelper-hint">{hint}</span>' if hint else ""}</figcaption>'
                f'<div class="zhelper-app" style="height: {height}px"><p class="zhelper-poster">It starts when it comes into view. It needs JavaScript and WebAssembly.</p></div>'
                f'<details><summary>How {what} is made: {lines} lines of Tcl with the ztk GUI toolkit</summary><pre><code class="language-tcl">{html.escape(script)}</code></pre></details></figure>\n')

    def render(self, src, page, text=None):
        if text is None:
            text = (ROOT / src).read_text(encoding="utf-8")
        tokens = self.live_blocks(src, self.md.parse(text))
        ids, seen, title, linked = set(), {}, None, set()
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
                kids = token.children or []
                for k, child in enumerate(kids):
                    if child.type == "link_open" and child.attrGet("href") == "run:":
                        # A Run link: [`command`](run: "result"). A click runs
                        # the command in the course shell.
                        code = kids[k + 1] if k + 1 < len(kids) else None
                        if code is None or code.type != "code_inline" or kids[k + 2].type != "link_close":
                            raise SystemExit(f"{src}: a run: link has one code span: {inline_text(token)}")
                        cmd = html.escape(code.content, quote=True)
                        want = child.attrGet("title")
                        want = "" if want is None else f' data-want="{html.escape(want, quote=True)}"'
                        child.type, child.tag = "html_inline", ""
                        child.content = f'<span class="zrun" role="button" tabindex="0" data-cmd="{cmd}"{want} aria-label="Run in the shell: {cmd}">'
                        kids[k + 2].type, kids[k + 2].content = "html_inline", "</span>"
                    elif child.type == "link_open":
                        child.attrSet("href", self.link(src, page, child.attrGet("href")))
                    elif (page.startswith("learn/") and child.type == "code_inline" and child.content in self.ref_names
                          and child.content not in linked and not (k > 0 and kids[k - 1].type in ("link_open", "html_inline"))):
                        # The first mention of a command in a lesson links
                        # to its page of the command reference.
                        linked.add(child.content)
                        target = rel(page, self.ref_names[child.content])
                        child.type, child.tag = "html_inline", ""
                        child.content = f'<a class="ref-link" href="{target}"><code>{html.escape(child.content)}</code></a>'
        self.anchors[page] = ids
        self.checkpoints[page] = self.checkpoint
        self.files_of[page] = self.page_files
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
        course, dock = page.startswith("learn/") or (page.startswith("reference/") and page != "reference/"), ""
        if course:
            setup = self.checkpoints.get(page) or ""
            dock = self.course_html(page, setup, self.files_of.get(page) or {})
            if setup:
                body += (f'<details class="zsetup"><summary>The state of the shell at the start of this lesson</summary>'
                         f'<pre><code class="language-tcl">{html.escape(setup)}</code></pre></details>\n')
        if 'class="zshell' in body or course:
            script += f'\n<script type="module" src="{root}assets/shell.js"></script>'
        if 'class="zhelper"' in body:
            script += f'\n<script type="module" src="{root}assets/helper.js"></script>'
        desc = "A sandboxed Tcl interpreter in Zig, with a bytecode VM and a JIT."
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name}</title><meta name="description" content="{desc}">
<link rel="canonical" href="{SITE}{page}">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}assets/site.css">{script}</head>
<body{' class="course"' if course else ''}><a class="skip" href="#content">Skip to the content</a>
<header class="top"><div class="wrap"><a class="logo" href="{root}"><span class="glyph" aria-hidden="true">tc</span>ztcl</a>
<nav class="toplinks" aria-label="Site"><a href="{root}overview/" aria-current="page">Docs</a><a href="{root}playground/">Playground</a><a href="{root}try/">Shell</a><a class="sib" href="https://beetlebug.org/ztk/">ztk</a><a href="{REPO}">GitHub</a></nav></div></header>
<div class="docs"><input class="toc-toggle" type="checkbox" id="toc"><label class="toc-button" for="toc">Contents</label>
<aside class="sidebar"><nav aria-label="Documentation">{self.nav(page)}</nav></aside>
<main class="prose" id="content">{body}{self.pager(page) if any(p == page for _, p, _, _ in PAGES) else ""}</main></div>{dock}
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
            if full in ("llms.txt", "llms-full.txt", "reference/api.json"):
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
        lines.append(f"\n## For agents\n\n- [Full text]({SITE}llms-full.txt): the Markdown of each page above and of each command.\n"
                     f"- [api.json]({SITE}reference/api.json): each command with its synopsis, options, subcommands, capability, compute cost, examples, and errors.\n"
                     f"- [ztk](https://beetlebug.org/ztk/llms.txt): Tk on ztcl, for GUI apps.\n")
        (out / "llms.txt").write_text("".join(lines), encoding="utf-8")
        (out / "llms-full.txt").write_text("".join(full), encoding="utf-8")

    def reference_pages(self):
        """The pages of the command reference (tools/reference.py), and the
        list of each area for the index page reference/."""
        entries = reference.parse()
        pages, areas = [], []
        for area, label in reference.AREAS:
            items = [e for e in entries if e["area"] == area]
            if not items:
                continue
            rows = []
            for e in items:
                slug = reference.slug(e["name"])
                page = f"reference/{slug}/"
                text = reference.markdown(e, lambda n: n)
                title, body = self.render(f"docs/reference/{slug}/index.md", page, text)
                pages.append((page, title, body))
                cap = f' <span class="ref-cap">{html.escape(e["cap"])}</span>' if "cap" in e else ""
                first = e["does"].split(". ")[0].rstrip(".") + "."
                rows.append(f'<li data-name="{html.escape(" ".join(reference.names(e)).lower())}"><a href="{slug}/"><code>{html.escape(e["name"])}</code></a>{cap} {re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(first))}</li>')
            areas.append(f'<section class="ref-area"><h2 id="{area}">{html.escape(label)}</h2><ul class="ref-list">{"".join(rows)}</ul></section>')
        index = ('<p class="ref-search"><label>Find a command <input type="search" id="ref-q" autocomplete="off" spellcheck="false" placeholder="lsort, dict get, socket"></label></p>'
                 '<p class="ref-none" hidden>No command matches.</p>' + "".join(areas) +
                 '<script>{const q=document.getElementById("ref-q"),none=document.querySelector(".ref-none");'
                 'q.addEventListener("input",()=>{const t=q.value.trim().toLowerCase();let n=0;'
                 'document.querySelectorAll(".ref-list li").forEach(li=>{const on=!t||li.dataset.name.includes(t)||li.textContent.toLowerCase().includes(t);li.hidden=!on;if(on)n++;});'
                 'document.querySelectorAll(".ref-area").forEach(s=>{s.hidden=!s.querySelector("li:not([hidden])");});none.hidden=n>0;});}</script>')
        self.reference_md = [(page, reference.markdown(e, lambda n: n)) for e in entries for page in [f"reference/{reference.slug(e['name'])}/"]]
        self.api_json = reference.api(entries)
        return pages, index

    def run(self, out):
        ref_pages, ref_index = self.reference_pages()
        rendered = [(page, *self.render(src, page)) for src, page, _, _ in PAGES]
        rendered = [(p, t, b + ref_index if p == "reference/" else b) for p, t, b in rendered] + ref_pages
        for src, page, anchor in self.links:
            if anchor not in self.anchors.get(page, set()):
                raise SystemExit(f"{src}: link to a missing anchor: {page}#{anchor}")
        for name in WASM_FILES:
            if not (ROOT / "zig-out" / "lib" / name).exists():
                raise SystemExit(f"zig-out/lib/{name} is missing: run `zig build wasm wasm-threads wasm-shell wasm-host` first")
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
        for name in ("site.css", "favicon.svg", "live.js", "shell.js", "helper.js"):
            shutil.copy(SITE_DIR / name, out / "assets" / name)
        (out / "try").mkdir()
        shutil.copy(SITE_DIR / "try" / "index.html", out / "try" / "index.html")
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
        # learn/ was one long page. Its old anchors go to their lessons.
        table = {a: rel("learn/", p) for a, n in LEARN_ANCHORS.items() for _, p, _, _ in LESSONS if p.startswith(f"learn/{n}-")}
        first = rel("learn/", FIRST_LESSON)
        (out / "learn" / "index.html").write_text(
            f'<!doctype html><meta charset="utf-8"><title>Learn Tcl</title>'
            f'<link rel="canonical" href="{SITE}{FIRST_LESSON}">'
            f'<script>const t = {json.dumps(table)}; location.replace(t[location.hash.slice(1)] || "{first}");</script>'
            f'<meta http-equiv="refresh" content="0; url={first}"><a href="{first}">The course starts here.</a>\n',
            encoding="utf-8")
        self.agents(out)
        (out / "reference" / "api.json").write_text(self.api_json, encoding="utf-8")
        with (out / "llms-full.txt").open("a", encoding="utf-8") as f:
            for page, text in self.reference_md:
                f.write(f"\n\n<!-- {SITE}{page} -->\n\n{text}")
        (out / ".nojekyll").write_text("", encoding="utf-8")
        print(f"wrote {len(rendered) + len(HTML_PAGES)} pages to {out}")


if __name__ == "__main__":
    Build().run(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out" / "docs-site")
