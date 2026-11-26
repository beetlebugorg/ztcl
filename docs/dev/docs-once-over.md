# The docs once-over (issues 173 and 172)

This file is the plan and the state of the once-over. It is not on the site.

## Done

- #196: the build drops the comment lines of the Markdown. A `<!-- run -->` block is a live example, and its `text` block shows until it runs. A live example of `ztcl::vt` has a Screen button. `tests/site.sh` fails on a page that shows `&lt;!--`.

## The design (user, 2026-11-26)

Each docs page gets the shell of the page (`docs/site/shell.js`, `ztcl-shell.wasm`), opened with the state of the page loaded, and beside it a small ztk app, the helper. The helper has entries, spinboxes, comboboxes, and check buttons for the values and the flags of one command. It shows the exact command that it builds and its result as the reader types, and a button puts the command into the shell. Examples: `string map`, `regexp` with the matches highlighted, `lsort` with its options, `clock format`, `dict` as a small table, and `expr` as a calculator.

- One shared component: the shell and the helper. Each helper is a short Tcl and ztk script next to the page text, for example a `<!-- helper: NAME -->` line before a `tcl` block that `tools/build-docs.py` turns into the component.
- The helper runs in ztk.wasm from beetlebug.org/ztk (the live snippet of ztk), and the shell in ztcl-shell.wasm. The button gives the command to the shell with `Shell.setLine`.
- The mantra: text first, no part starts by itself, a static image until the runtime loads, works with no JavaScript, keyboard and screen reader friendly, no quizzes.

## The JSON page and the inspector (user, 2026-11-26)

- On the JSON page the reader pastes or loads JSON, and the shell has it: `set d [ztcl::json parse $text]`, and `puts $d` shows it. `ztcl::json pretty` gives the pretty form. The files of the page (the read-only files of `Shell.create`) have two or three sample JSON files.
- An inspector shows a value as a tree: a dict as key and value rows, a list as numbered rows, and nested values folded. Each node shows its path, for example `dict get $d users 0 name`, and one click puts that path into the shell.
- The inspector works for each value of the shell: a key opens it on the last result.

## State

- The component is done: `<!-- shell -->` before a `tcl` block puts the shell of the page there, and the block is the state of the page. `<!-- file: NAME -->` makes a code block a read-only file of that shell. `<!-- helper: TITLE -->` makes a `tcl` block a helper. `docs/site/helper.js` runs it in ztk.wasm from `/ztk/play/ztk.js` and gives it the procs `helper::form`, `helper::row`, `helper::watch`, `helper::show`, `helper::run`, and `helper::footer`. A helper runs its commands in the interpreter of the shell, so the result is the result of the shell. `tools/site-helper.mjs` tests it.
- "Learn Tcl" (`docs/learn.md`) has the sections of #173 and the helpers `expr`, `lsort`, `dict`, `string map`, and `regexp`. The shell has a small text game in its state.
- The JSON page has the shell, two sample files, and the inspector.
- `clock format` has no helper: `ztcl-shell.wasm` is a build with no host imports, so it has no `ztcl_clock_allow` (only `ztcl-host.wasm` has it, since ztcl #194). See the questions file.
- Learn Tcl has helpers for `proc`, `namespace`, `catch`, reading a file, and `info class`. The shell state has the namespace `counter` and the class `Account`. The coroutine example is `<!-- run: native -->`: the WebAssembly builds have no `coroutine`.
- The vt page has a shell and a feed helper. The watch, open, and notify pages have helpers with `# shell: none`: they build the command and show its shape in the page, with no shell.
- Alt-I in the shell opens the inspector on the last result (`Shell.lastResult`), and sets `_` to it.
- On a screen of 640 pixels or less, a helper is one line with an Open button.
- `docs/targets.md`, with `tests/targets.sh` in the docs job of CI. `docs/modules/README.md` and the Modules section of the nav and of llms.txt.

## Next, in order

1. A helper for `clock format` when the page shell has a clock (see the questions file).
2. A pass over each page for accuracy against main (#173).

Resume: build with `zig build wasm wasm-threads wasm-shell` (own ZIG_LOCAL_CACHE_DIR and ZIG_GLOBAL_CACHE_DIR, memory cap), then `python3 tools/build-docs.py site && sh tests/site.sh site`. For the helpers, serve the site at `/ztcl/` and a ztk web build at `/ztk/play/`, and run `node tools/site-helper.mjs chromium URL` (see the top of that file).
