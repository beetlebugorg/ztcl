# The Learn course

This file is the design of the Learn section of the docs site. It replaces the one long page `docs/learn.md`. It is not on the site.

## The reader and the aim

Many readers do not write most of their code now. An agent writes it, and the person reads it, judges it, and steers the agent. The course teaches Tcl well enough for that: to read a script, to say what it does and where it can go wrong, and to fix it. The reader learns these skills by changes to code in the shell.

- A programmer who knows Python, JavaScript, or Go. The course does not teach programming.
- A person who reads Tcl that an agent wrote, and must judge what it does and what it can reach.

The course still covers the language fully and correctly. A reader who finishes it can review a script and fix it with confidence.

## What the user asked for (2026-11-26)

- Fewer boxes of code. One short example for each idea.
- Helpers that say what they are for, and only where a form is better than typing.
- "Put in the shell" must not move the page.
- A walkthrough of the basics, linked from the landing page as "Start here".
- Short lessons with next and previous links.
- The agent side in each part, practical and checkable.

## The shape

The course is 15 lessons of about 5 minutes. Each lesson has one idea. Each lesson adds one capability to one project, `jot`, a small notes tool. The examples are code that the reader will see, often from an agent. Each example says what the code does and where it can go wrong. The exercises are "change this and see" on code that is already in the shell, and seldom a new script from an empty line.

| # | Lesson | The idea, and the traps to look for | What `jot` gets |
|---|---|---|---|
| 1 | Read a command | A command is words. `$`, `[ ]`, `{ }`, and `" "`, with the Python and JavaScript forms next to them. Traps: a missing brace around an `expr`, double substitution. | A first note |
| 2 | Variables and math | `set`, `incr`, `expr` in braces, each value a string. Traps: integer division, `expr` with no braces on input. | A count of notes |
| 3 | Lists and dicts | `list`, `lappend`, `lindex`, `dict`. Traps: a string used as a list, a list built with `"..."`. | Notes as a list of dicts |
| 4 | Procs and control flow | `proc`, `if`, `foreach`, `return`, `global`, `upvar`. Traps: `upvar` to the wrong level, a body in quotes. | `add` and `show` |
| 5 | Strings and patterns | `string`, `split`, `join`, `format`, `regexp`. Traps: a pattern in quotes, `regexp` with no anchors. | Tags such as `#home` |
| 6 | Errors | `error`, `try`, `catch`, `return -code`, `errorInfo`. Traps: a `catch` that hides each error. | A check of the input |
| 7 | Namespaces | `namespace eval`, `variable`, an ensemble. | `jot add` and `jot show` |
| 8 | Files and JSON | Channels, `ztcl::json`. Traps: a file that is not closed, a path from input. | Notes in `notes.json` |
| 9 | Events | `after`, `vwait`, `coroutine` and `yield`. | A reminder |
| 10 | Objects | `oo::class`, methods, `my`. | A `Note` class |
| 11 | A small service | `socket -server` on loopback, a line protocol. Traps: input that becomes code. | `jot` answers on a port |
| 12 | A window | A ztk window that lists and adds notes. | A GUI |
| 13 | The sandbox | Capabilities and the compute limit: what a script can reach, and a loop that stops at the limit. | Runs with only `file` |
| 14 | An agent writes a part | The reader gives a prompt, gets an export feature from an agent (the course shows a recorded answer), reviews it, and runs it under a compute limit and a capability list. A bad change (a write outside the folder, an `exec`) stops at the sandbox with an error. Later the sandboxed agent of ztcl issue 216 runs here live. | Export to Markdown |
| 15 | Ship it | `ztcl build` to one binary, its capabilities, and the JIT and threads in short. | One binary |

Lessons 1 to 4 are "Read Tcl in 15 minutes", the "Start here" link of the landing page. A newcomer goes through them from start to end in the shell. The good parts of the old page (the substitution rules, "Mistakes to avoid", "Coming from tclsh") go into these lessons.

## The agent in each lesson

- Each lesson ends with "Reading code an agent wrote": two to four checks for the idea of the lesson, and what a good result looks like. For example, lesson 2: "Each `expr` has braces. A value from input never goes into `expr` without them."
- Each lesson has one prompt that gives idiomatic ztcl from an agent, for example "Use a dict for each note, `dict get` with a default, and `try` with `trap` for the errors". The prompts are text. The page makes no API call.
- The course points an agent to `llms.txt`, `llms-full.txt`, and the api.json of the command reference.

## The advanced track

The advanced track comes after lesson 15. Its lessons are longer, and each one is one job from start to end.

| Lesson | The job |
|---|---|
| Write a package | A namespace, `package provide`, `pkgIndex.tcl`, tests with `tcltest`, docs, and version numbers. Then the ways to give it to others: a `.tm` module, and a package in a binary of `ztcl build`. The ztcl part: declare the capabilities that the package needs, and give its users a compute cost for each command. The agent part: a capability list in one place, examples that run in CI, and a docs page in the shape of the command reference, so that an agent can call the package correctly. |
| A C package | A package in C through the stubs table, when issue 1 is far enough. |
| Threads and isolation | The isolation levels of ztcl, and when to use each one. |
| Coroutines in depth | Generators, pipelines, and a scheduler of coroutines on the event loop. |
| A ztk app | An app from the first window to a binary for each platform. |

"Write a package" is first. The others follow as their features are ready.

## The shell of the course

- One shell for the whole course. It is docked in the window: a panel at the right side on a wide screen (1,100 pixels and more), and a sheet at the bottom on a smaller screen, that the reader can make small. It is always in view, and the page never scrolls to it.
- The state goes from lesson to lesson. Each lesson has a checkpoint: the Tcl state of `jot` at the start of that lesson, in the source of the lesson. A page loads its checkpoint, and then the commands that the reader ran on this lesson, from `sessionStorage`. The commands of the earlier lessons do not run again, because the checkpoint has their state, and a second run of `add` makes a second note. "Start again" clears them. A reader who opens lesson 9 from a link gets the checkpoint of lesson 9 and a working `jot`.
- The files of the shell are in memory and writable, so that lesson 8 can write `notes.json`. They go away with the tab.
- Lesson 11 needs a socket. The web build has no network. The page runs the server and a client in one interpreter over a pair of in-memory channels. The lesson also gives the command for a real port on the reader's computer.

## Examples

- An example is a "Run" link in the text: a button with a short command in code type. A click puts the command in the shell and runs it. The result shows in the shell, and the page does not move.
- A lesson has at most one code box: the proc or the class of the lesson, with a Run button that defines it in the shell.
- Each lesson ends with two or three "Try this" lines: a change to make in the shell. No quizzes.
- Each Run link and each code box runs in CI with the checkpoint of its lesson. The source gives the expected result after the command, and CI checks it (`tools/doc-examples.py`).

## Helpers and toys

A helper is a ztk form that makes a command. The course keeps a helper only where the form is better than typing:

- Lesson 5: Build a regexp. Type a pattern and a string, and see the matches and the groups in colors.
- Lesson 8: Inspect JSON. Click a node, and get the `dict get` path to it.
- Lesson 13: The compute limit. Move a slider for the limit and run a loop, and see where it stops.

Each helper has a title, a caption of one line, and a "Tool" tag. The code of the helper is in a folded section. The other helpers of the current page go away: `expr`, `lsort`, `dict`, `string map`, `proc`, the namespace helper, the error helper, the file helper, and `info class` add little over the shell.

Lesson 12 has one toy: the `jot` window in a live ztk snippet, with its code next to it.

## The command reference

The issue "Command reference" is a separate job, with its own design. A lesson links each command that it uses to its page in the reference, and the course does not repeat it. The reference is for a person who checks what a call does and for an agent that writes the call. Each page has one machine-readable form in `llms-full.txt` and the api.json: the synopsis, the options, the errors, the compute cost, the capability, and examples. A command that needs a capability has a mark, so that an agent knows to ask for it.

## The source

- `docs/learn/NN-slug.md`, one file for each lesson, with `<!-- checkpoint -->` at the top and the Run links as ``[`cmd`](run:)``, with the expected result as the title of the link: ``[`cmd`](run: "result")``. A result of `error: MESSAGE` expects an error. `<!-- define -->` before a `tcl` block makes the code box of the lesson. A lesson from number 90 is in the advanced track.
- `tools/build-docs.py` makes the pages `/ztcl/learn/NN-slug/`, the next and previous links, and the sidebar group "Learn".
- `/ztcl/learn/` is lesson 1. The old anchors of `/ztcl/learn/` (`#lists`, `#procs`) go to their lessons with a small redirect table in the page.

## Order of the work

1. The shell does not move the page (done on a branch): a shell out of view docks in the window, and a "Keep in view" button docks it. `tools/site-helper.mjs` checks that `scrollY` stays the same after "Put in the shell".
2. This design, for review.
3. Lessons 1 to 4 ("Read Tcl in 15 minutes") and the course shell. "Start here" on the landing page.
4. Lessons 5 to 15, then "Write a package".
5. The command reference.

## Questions

1. Is `jot` a good project? Default: yes.
2. Lesson 11 runs over in-memory channels in the page. Default: yes, and a real port in the text.
3. The reader's commands go to `sessionStorage` (per tab). Default: yes; `localStorage` keeps them after the tab closes.
4. Lesson 14 shows a recorded answer of an agent until issue 216 is ready. Default: yes, with the prompt and the review steps.
