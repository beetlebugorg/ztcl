# Module ztcl::vt

`ztcl::vt` keeps the state of a terminal: the grid of cells, the cursor, the modes, the title, and the scrollback. A script feeds it the bytes of a program and reads back the rows, the cells, and the rows that changed. The parser and the state are libghostty-vt 1.0.2, the terminal library of Ghostty, which the build compiles into the binary. [References](../references/ghostty.md) lists the sources.

> [!NOTE]
> `ztcl::vt` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

The module needs no capability. It reads no file and starts no process. Its memory counts toward the memory limit of the interpreter. Use it for tests of terminal output, for a terminal widget, and for tools that read the screen of a program on a `ztcl::pty`.

<!-- run -->
```tcl
package require ztcl::vt
set t [ztcl::vt new -size {40 10}]
ztcl::vt feed $t "hello\r\n\x1b\[1mbold\x1b\[0m"
puts [ztcl::vt rows $t 0 1]
puts [ztcl::vt cursor $t]
ztcl::vt delete $t
```

```text
hello bold
4 1
```

## Synopsis

```tcl
package require ztcl::vt
ztcl::vt new ?-size {COLS ROWS}? ?-scrollback LINES?
ztcl::vt feed T BYTES
ztcl::vt resize T COLS ROWS
ztcl::vt size T
ztcl::vt cursor T
ztcl::vt modes T
ztcl::vt rows T ?FIRST? ?LAST?
ztcl::vt cells T ?FIRST? ?LAST?
ztcl::vt dirty T
ztcl::vt scrollback T
ztcl::vt title T
ztcl::vt bells T
ztcl::vt delete T
```

`T` is a handle from `new`. A handle is valid in the interpreter that made it, until `delete` or the end of the interpreter.

## Commands

### new

```tcl
ztcl::vt new ?-size {COLS ROWS}? ?-scrollback LINES?
```

Makes a terminal and gives its handle, `vt0` for the first one. The options:

| Option | Value | Default |
|---|---|---|
| `-size {COLS ROWS}` | Each size is 1 to 4,096. | `{80 24}` |
| `-scrollback LINES` | The most lines of scrollback, 0 to 1,000,000. libghostty-vt keeps whole pages of rows, so the scrollback can hold more lines than `LINES`. | 1,000 |

The cursor starts at row 0, column 0. The colors that the OSC queries 10 and 11 report are black on white.

### feed

```tcl
ztcl::vt feed T BYTES
```

Feeds the UTF-8 bytes of the string `BYTES` to the parser. A sequence can end in a later `feed`. The result is the reply of the terminal: the bytes that a program gets back for DA (`ESC [c`), DSR (`ESC [5n`, `ESC [6n`), the mode queries, and the OSC color queries. A caller sends the reply to the program. The result is empty when no sequence asks for a reply.

<!-- run -->
```tcl
package require ztcl::vt
set t [ztcl::vt new -size {20 4}]
set r [ztcl::vt feed $t "abc\x1b\[6n"]
puts [string map [list \x1b ESC] $r]
```

```text
ESC[1;4R
```

The bell (BEL) adds 1 to the count of `bells`. OSC 0 and OSC 2 set the title. A sequence that libghostty-vt does not handle has no effect.

### resize

```tcl
ztcl::vt resize T COLS ROWS
```

Changes the size. Each size is 1 to 4,096. The text of the primary screen reflows to the new width, and the rows above the cursor go to the scrollback when the screen gets shorter. The result is empty.

### size and cursor

```tcl
ztcl::vt size T
ztcl::vt cursor T
```

`size` gives the list `COLS ROWS`. `cursor` gives the list `X Y` of the cursor in the active area, from 0.

### modes

```tcl
ztcl::vt modes T
```

Gives a dict of the modes:

| Key | Value |
|---|---|
| `cursor_keys_app` | 1 after DECCKM (`ESC [?1h`) |
| `keypad_app` | 1 after DECNKM (`ESC [?66h`) |
| `cursor_visible` | 0 after `ESC [?25l` |
| `bracketed_paste` | 1 after `ESC [?2004h` |
| `focus_events` | 1 after `ESC [?1004h` |
| `mouse_sgr` | 1 after `ESC [?1006h` |
| `alt_screen` | 1 while the alternate screen is active (`ESC [?1049h`) |
| `mouse` | `none`, `x10`, `normal`, `button`, or `any` (modes 9, 1000, 1002, and 1003) |
| `cursor_style` | The DECSCUSR number: 1 or 2 for a block, 3 or 4 for an underline, 5 or 6 for a bar. An odd number blinks. |

<!-- run -->
```tcl
package require ztcl::vt
set t [ztcl::vt new]
ztcl::vt feed $t "\x1b\[?1049h\x1b\[?1000h\x1b\[?1006h"
set m [ztcl::vt modes $t]
puts [list [dict get $m alt_screen] [dict get $m mouse] [dict get $m mouse_sgr]]
```

```text
1 normal 1
```

### rows

```tcl
ztcl::vt rows T ?FIRST? ?LAST?
```

Gives a list with the text of each row from `FIRST` to `LAST`, with the trailing blanks removed. Row 0 is the top of the active area. A negative row is a line of the scrollback: -1 is the last line. With no index, the list has each row of the active area. With one index, the list has that row. An index outside the screen is clamped to the first or the last row.

<!-- run -->
```tcl
package require ztcl::vt
set t [ztcl::vt new -size {10 2}]
ztcl::vt feed $t "one\r\ntwo\r\nthree"
puts [ztcl::vt scrollback $t]
puts [ztcl::vt rows $t -1 1]
```

```text
1
one two three
```

### cells

```tcl
ztcl::vt cells T ?FIRST? ?LAST?
```

Gives one list for each row, as `rows` does. Each row is a list of `COLS` cells, and a cell is the list `TEXT WIDTH FG BG ATTRS`:

- `TEXT` is the character of the cell, or empty for a cell with no character.
- `WIDTH` is 1, 2 for a wide character, or 0 for the cell after a wide character.
- `FG` and `BG` are empty for the default color, an index of the 256-color palette, or `#rrggbb`.
- `ATTRS` lists `bold`, `dim`, `italic`, `underline`, `blink`, `inverse`, `hidden`, and `strike`.

<!-- run -->
```tcl
package require ztcl::vt
set t [ztcl::vt new -size {4 1}]
ztcl::vt feed $t "\x1b\[1;31mA\x1b\[0m\x1b\[48;2;0;128;255mB\x1b\[0m中"
foreach c [lindex [ztcl::vt cells $t 0] 0] {puts $c}
```

```text
A 1 1 {} bold
B 1 {} #0080ff {}
中 2 {} {} {}
{} 0 {} {} {}
```

### dirty

```tcl
ztcl::vt dirty T
```

Gives the rows of the active area that changed since the last call of `dirty`, in order. The first call gives each row. A change of the size or of the colors gives each row. A move of the cursor changes the row that it leaves and the row that it goes to.

<!-- run -->
```tcl
package require ztcl::vt
set t [ztcl::vt new -size {10 3}]
ztcl::vt dirty $t
ztcl::vt feed $t "\x1b\[3;1Hx"
puts [ztcl::vt dirty $t]
puts [llength [ztcl::vt dirty $t]]
```

```text
0 2
0
```

### scrollback, title, and bells

```tcl
ztcl::vt scrollback T
ztcl::vt title T
ztcl::vt bells T
```

`scrollback` gives the count of lines in the scrollback. The alternate screen has no scrollback. `title` gives the title from OSC 0 or OSC 2, or empty. `bells` gives the count of BEL characters since `new`.

### delete

```tcl
ztcl::vt delete T
```

Frees the terminal. The handle is then invalid. The interpreter frees each terminal that is left when it ends or when an embedder calls `Interp.reset`.

## Errors

| Error code | Message | Cause |
|---|---|---|
| `TCL WRONGARGS` | `wrong # args: should be "..."` | A subcommand got the wrong count of arguments. |
| `TCL LOOKUP SUBCOMMAND` | `unknown subcommand "X": must be new, feed, ...` | An unknown subcommand. |
| `TCL LOOKUP OPTION` | `bad option "X": must be -size or -scrollback` | An unknown option of `new`. |
| `ZTCL VT HANDLE` | `can not find terminal "X"` | A handle that `new` did not give, or a deleted handle. |
| `ZTCL VT SIZE` | `the size N is outside 1 to 4096` | A size of `new` or `resize`. |
| `ZTCL VT SCROLLBACK` | `the scrollback N is outside 0 to 1000000` | The value of `-scrollback`. |

A terminal that needs more memory than the memory limit stops the script with the memory error of the interpreter.

<!-- run -->
```tcl
package require ztcl::vt
puts [list [catch {ztcl::vt size vt9} m o] $m [dict get $o -errorcode]]
```

```text
1 {can not find terminal "vt9"} {ZTCL VT HANDLE}
```

## Platforms

- The module is in each build with the `std` preset: the runner and the library on Linux, macOS, and Windows, x86-64 and arm64, `ztcl.wasm`, `ztcl-async.wasm`, and `wasm32-wasi`. `-Dmod-vt=false` leaves it out.
- The WebAssembly build with shared threads (`ztcl-threads.wasm`) has no `ztcl::vt`, since libghostty-vt uses the allocator of a single-threaded WebAssembly memory.
- The build compiles libghostty-vt with `-Dsimd=false`, so it has no libc and no C++ code, and the Kitty graphics protocol is off.

## In Zig

`@import("ztcl").vt.Term` is the same state for a Zig program: `create`, `destroy`, `write`, `resize`, `row`, `cursor`, `cursorStyle`, `modes`, `dirty`, `title`, and the field `reply`. `ztk::terminal` uses it. A program root that links the module sets `std_options.logFn` to `vt.noLog` or to its own filter, since libghostty-vt logs the sequences that it does not handle.
