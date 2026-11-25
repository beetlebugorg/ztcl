# References of the interactive shell

The shell (`src/shell/`) is fresh code. These sources gave its rules and its behavior. No code was copied.

- ECMA-48, "Control Functions for Coded Character Sets", and the xterm control sequences document by Thomas Dickey: the escape sequences of the terminal (cursor moves, erase, SGR colors, the cursor shape of DECSCUSR, bracketed paste 2004). https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- POSIX `termios` and the `TIOCGWINSZ` ioctl: raw mode and the window size.
- Unicode Standard Annex #11, East Asian Width, and Annex #29, Text Segmentation: the width of a character and the joined clusters. The tables of `text.zig` are short ranges of the Unicode data.
- The manuals of GNU Readline, Vim, and fish: the key bindings, the vim operators and text objects, and the history hint. https://tiswww.cwru.edu/php/chet/readline/rluserman.html, https://vimhelp.org/, https://fishshell.com/docs/current/
- Microsoft, "Console Virtual Terminal Sequences" and the console API: the modes of the Windows console. https://learn.microsoft.com/windows/console/console-virtual-terminal-sequences
- The NO_COLOR convention. https://no-color.org/
