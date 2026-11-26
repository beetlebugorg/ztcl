# Read a command

This course teaches Tcl to a programmer who reads code, often code from an agent, and must say what it does and fix it. Lessons 1 to 4 are "Read Tcl in 15 minutes". Each lesson adds one part to `jot`, a small notes tool.

The shell of the course is at the side of the page, or at the bottom on a small screen. A Run link, such as [`puts "Hello, jot"`](run: ""), puts its command in the shell and runs it. The page stays where it is. The shell keeps your commands for this lesson until you close the tab, and "Start again" clears them.

## A command is words

A Tcl script is a list of commands, one on each line. A command is a list of words with spaces between them. The first word is the name of the command, and the other words are its arguments.

[`set note "buy milk"`](run: "buy milk") makes the variable `note`. `jot` now has its first note. [`string length $note`](run: "8") gives the count of its characters.

`if`, `while`, and `proc` are commands like `set`. Their bodies are words in braces. The command gets the body as text, and runs it when it is time.

## Four kinds of words

Tcl changes a word before it calls the command. This table is all of the syntax.

| Tcl | Python | JavaScript | What Tcl does |
|---|---|---|---|
| `$note` | `note` | `note` | Puts the value of the variable in the word. |
| `[string length $note]` | `len(note)` | `note.length` | Runs the script in the brackets and puts its result in the word. |
| `"Note: $note"` | `f"Note: {note}"` | `` `Note: ${note}` `` | Makes one word with spaces, and does the two changes above in it. |
| `{Note: $note}` | `r"Note: $note"` | `"Note: $note"` | Makes one word with no changes. |

Run each one and compare: [`puts "Note: $note"`](run: "") and [`puts {Note: $note}`](run: ""). Brackets go in each other: [`string toupper [string range $note 0 2]`](run: "BUY").

A backslash escapes one character. `\n` is a newline, and `\$` is a dollar sign.

## Tcl changes a word one time

Tcl does the changes on each word once. A value that has `$` or `[` in it stays as text, until a command such as `expr` or `eval` reads it as code again. That second read is the most important trap of Tcl.

Make a value with code in it: [`set input {[puts gotcha]}`](run: "[puts gotcha]"). With braces, `expr` reads the variable as a value: [`expr {$input}`](run: "[puts gotcha]"). With no braces, Tcl puts the text in the word first, and `expr` then runs it as code: [`expr $input`](run: ""). The shell prints `gotcha`.

## Reading code an agent wrote

- Each `expr` has its expression in braces: `expr {$a + $b}`.
- A value from a user, a file, or a network goes to `eval`, `uplevel`, or `expr` only in braces or as a list.
- A word with spaces is in quotes or braces. `set note buy milk` is an error: `set` gets three words.

## Ask an agent

> Write Tcl that prints the length of each word of a sentence. Put each `expr` in braces, and use no `eval`.

Check the answer with the list above.

## Try this

- Run `set note "call Ada"`, and run the `puts` links again.
- Make `puts "a\tb"` print a tab, then make it print `\t`.
- Find the result of `string length "$note$note"` before you run it.
