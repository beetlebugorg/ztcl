# An agent writes a part

This lesson puts the earlier lessons to work. You give an agent a prompt for a feature of `jot`, read its answer, and run it under the sandbox. The page shows an example answer. Issue [#216](https://github.com/beetlebugorg/ztcl/issues/216) adds an agent that runs in a sandboxed thread of ztcl, and then this lesson runs one live.

<!-- checkpoint -->
```tcl
namespace eval jot {
    variable notes [list [dict create text "buy milk" done 1] [dict create text "fix the bike #home" done 0]]
}
```

## The prompt

> Add `jot::export_md` to the `jot` namespace. It gives the notes as a Markdown task list with the title "Notes". Escape the Markdown characters of the text. Use no capability: the proc gives a string, and the caller writes it.

The last sentence is the important one. A proc that gives a string needs no `file`, so the caller decides where the text goes.

## The answer

This is a good answer. Read it before you run it.

<!-- define -->
```tcl
proc jot::export_md {} {
    variable notes
    set lines [list "# Notes" ""]
    foreach n $notes {
        set box [expr {[dict get $n done] ? "x" : " "}]
        set text [string map {\\ \\\\ * \\* _ \\_ ` \\` [ \\[ ] \\]} [dict get $n text]]
        lappend lines "- \[$box\] $text"
    }
    return [join $lines \n]
}
```

## The review

Check it with the lists of the earlier lessons:

1. `variable notes` links the namespace variable (lesson 7). Without it, the proc gives an error.
2. `expr` has braces (lesson 2), and the list is built with `list` and `lappend` (lesson 3).
3. `string map` reads the string once, with the backslash first in the map. Each character of the map is in braces, so Tcl does not change it (lesson 1).
4. The proc uses no `open`, `exec`, or `socket` (lesson 13).

Then run it: [`jot::export_md`](run:). Check one value: [`lindex [split [jot::export_md] \n] 2`](run: "- [x] buy milk").

## A bad answer

This is the end of a bad answer to the same prompt:

```tcl
exec pandoc notes.md -o notes.pdf
set f [open ~/notes.md w]
```

The prompt said "use no capability", and the answer uses two. In the sandbox, each one is an error, and nothing outside the interpreter changes: [`catch {exec pandoc notes.md -o notes.pdf} msg`](run: "1") and [`catch {open ~/notes.md w} msg`](run: "1"). [`set msg`](run:) has the message.

Tell the agent what was wrong, in one line: "The proc uses `exec` and `open`; give the Markdown as the result, and use no capability."

## Run a part from an agent

1. Give the prompt the capabilities that the part can use, and the limits.
2. Read the answer with the lists of the lessons. Look first for `exec`, `open`, `socket`, `eval`, and `uplevel`.
3. Run it with only those capabilities and a compute limit: `ztcl --allow file,channels --root ./notes --compute 50000000 jot.tcl`.
4. Check one result that you know.

## Try this

- Add a note with `*` in its text, and run `jot::export_md` again.
- Change the prompt to ask for a `-done` option that leaves out the notes that are done.
- Give the prompt to your agent, and review its answer with the four checks.
