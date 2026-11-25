# The interactive shell

`ztcl` with no file starts an interactive shell when standard input and standard output are a terminal. With a pipe, a file, or `TERM=dumb`, the runner reads one command for each line, with no editor. The line editor is code of ztcl. It uses no readline, libedit, or ncurses, and it talks to the terminal with termios and ANSI escape sequences.

## Keys

Emacs keys are the default.

| Key | Action |
|---|---|
| Ctrl-A, Ctrl-E, Home, End | The start or the end of the line |
| Ctrl-B, Ctrl-F, Left, Right | One character back or forward |
| Alt-B, Alt-F, Ctrl-Left, Ctrl-Right | One word back or forward |
| Ctrl-W, Alt-Backspace, Alt-D | Kill a word back or forward |
| Ctrl-K, Ctrl-U | Kill to the end or the start of the line |
| Ctrl-Y, then Alt-Y | Yank the last kill, then an older kill |
| Ctrl-T | Swap the characters around the cursor |
| Ctrl-_ | Undo |
| Up, Down, Ctrl-P, Ctrl-N | The line above or below, and the history at the first or the last line |
| Ctrl-R | Search the history |
| Tab | Complete |
| Ctrl-X Ctrl-E | Edit the command in `$VISUAL` or `$EDITOR` |
| Alt-T | Show the whole `errorInfo` of the last error |
| Ctrl-L | Clear the screen |
| Ctrl-C | Drop the command |
| Ctrl-D | Exit, on an empty line |

`shell mode vi` turns on vim keys. Each command starts in insert mode, and Escape goes to normal mode. Normal mode has counts; the motions `h l w b e W B E 0 ^ $ f t F T ; ,`; the operators `d c y` with a motion, a doubled operator, or a text object (`iw aw i" a" i' a' i( a( i[ a[ i{ a{`); and `x X r R s S p P u Ctrl-R . ~ D C Y i a I A o O`. `"` and a letter name a register. `V` starts the visual mode. `v` opens the command in the editor, as in bash. `j` and `k` move between the lines of the command, and through the history at the first or the last line. The cursor is a block in normal mode and a bar in insert mode, and the prompt has its own color in normal mode.

## Input

- An open brace, bracket, or quote continues the command on the next line, with `info complete` as the test. The whole command edits as one buffer.
- A paste of many lines comes in as one command, with bracketed paste.
- Up with text before the cursor searches the history for that prefix. Ctrl-R searches with fuzzy matching: each character of the query must come in order. Escape keeps the match to edit it.
- A dim hint after the cursor is the newest history entry that starts with the command. Right arrow, Ctrl-F, or End accepts it.
- The row under the command shows the parameters of the proc of the command at the cursor.
- Tab completes command names, namespaces, variables after `$`, the subcommands of an ensemble, the methods of a TclOO object, and file names when the interpreter has `file` (the runner flag `--allow file`). A folder completes with a slash. With more than one match, a menu shows them, and Tab again puts in each one in turn.
- Colors show commands, strings, braces, variables, comments, and numbers. A command that does not exist shows in red before Enter. A bracket that matches the bracket at the cursor shows in reverse.

## Output

A result prints on its own row. A long list prints one item on each row, and a dict prints its keys in a column. An error prints its message in red, and Alt-T prints the whole `errorInfo`.

## Settings

`~/.ztclrc` runs at the start, in the interpreter. The command `shell` sets the shell:

```tcl
shell mode vi                    ;# or emacs
shell color command "1;34"       ;# a style and its SGR text
shell prompt myprompt            ;# the result of the proc is the prompt
shell history size 5000
shell bind ctrl-o edit           ;# ctrl-x or alt-x; accept, complete, clear-screen, edit, or trace
```

The styles are `plain`, `command`, `unknown`, `string`, `brace`, `variable`, `comment`, `number`, `match`, `prompt`, `prompt_normal`, `hint`, `select`, `menu`, and `menu_sel`. `NO_COLOR` in the environment turns the colors off.

The history is in `~/.ztcl_history`, at most 1000 commands by default. A command that starts with a space and a command equal to the last one stay out. Each shell adds its new commands to the file after each command, so two shells share it.

## Platforms

The shell runs on Linux and macOS. On Windows it uses the virtual terminal mode of the console. The Windows part builds, but no test runs it on Windows yet.

## Tests

`zig build test-shell` runs the tests of the editor, the history, the colors, and the screen with no terminal. `python3 -I tools/shell-pty.py` runs the real runner in a pseudo-terminal and checks the screen, the history file, the rc file, the editor of `VISUAL`, the completion of files and TclOO methods, and a resize of the window.
