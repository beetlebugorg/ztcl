# Module ztcl::vt

`ztcl::vt` keeps the state of a terminal: the grid of cells, the cursor, the modes, and the scrollback. A script feeds it the bytes of a program and reads back the rows, the cells, and the rows that changed. The parser and the state are libghostty-vt, the terminal library of Ghostty, which the build compiles into the binary. [References](../references/ghostty.md) lists the sources.

> [!NOTE]
> `ztcl::vt` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

The module needs no capability. It reads no file and starts no process. Its memory counts toward the memory limit of the interpreter. Use it for tests of terminal output, for a terminal widget, and for tools that read the screen of a program on a `ztcl::pty`.

```tcl
package require ztcl::vt
set t [ztcl::vt new -size {40 10}]
ztcl::vt feed $t "hello\r\n\x1b\[1mbold\x1b\[0m"
puts [ztcl::vt rows $t 0 1]      ;# hello bold
puts [ztcl::vt cursor $t]        ;# 4 1
ztcl::vt delete $t
```

## Commands

| Command | Result |
|---|---|
| `ztcl::vt new ?-size {COLS ROWS}? ?-scrollback LINES?` | A new handle. The default size is 80 by 24, and the default scrollback is 1,000 lines. |
| `ztcl::vt feed T BYTES` | Feeds the UTF-8 bytes of `BYTES` to the parser. The result is the reply of the terminal, for example the answer of `ESC [6n`. A caller sends the reply to the program. |
| `ztcl::vt resize T COLS ROWS` | Changes the size. Each size is 1 to 4,096. |
| `ztcl::vt size T` | The list `COLS ROWS`. |
| `ztcl::vt cursor T` | The list `X Y` of the cursor in the active area, from 0. |
| `ztcl::vt modes T` | A dict of the modes: `cursor_keys_app`, `keypad_app`, `cursor_visible`, `bracketed_paste`, `focus_events`, `mouse_sgr`, `alt_screen`, `mouse` (`none`, `x10`, `normal`, `button`, or `any`), and `cursor_style` (the DECSCUSR number). |
| `ztcl::vt rows T ?FIRST? ?LAST?` | The text of each row, with the trailing blanks removed. Row 0 is the top of the active area. A negative row is a line of the scrollback: -1 is the last line. |
| `ztcl::vt cells T ?FIRST? ?LAST?` | For each row, a list of cells. A cell is the list `TEXT WIDTH FG BG ATTRS`. `WIDTH` is 2 for a wide character and 0 for the cell after it. A color is empty for the default, an index of the 256-color palette, or `#rrggbb`. `ATTRS` lists `bold`, `dim`, `italic`, `underline`, `blink`, `inverse`, `hidden`, and `strike`. |
| `ztcl::vt dirty T` | The rows of the active area that changed since the last call. A change of the size gives each row. |
| `ztcl::vt scrollback T` | The count of lines in the scrollback. |
| `ztcl::vt title T` | The title from OSC 0 or OSC 2. |
| `ztcl::vt bells T` | The count of BEL characters. |
| `ztcl::vt delete T` | Frees the terminal. The interpreter frees each terminal that is left when it ends. |

The Kitty graphics protocol is off in this build. The WebAssembly build with shared threads (`ztcl-threads.wasm`) has no `ztcl::vt`, since libghostty-vt uses the allocator of a single-threaded WebAssembly memory.

## In Zig

`@import("ztcl").vt.Term` is the same state for a Zig program: `create`, `write`, `resize`, `row`, `cursor`, `modes`, `dirty`, and `reply`. `ztk::terminal` uses it.
