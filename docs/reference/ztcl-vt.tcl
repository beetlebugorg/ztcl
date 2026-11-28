# The command reference: ztcl::vt. The format is in
# docs/dev/reference-format.md.

command ztcl::vt {
    area ztcl
    since 1.0.0-beta.1
    setup {package require ztcl::vt; set vt [ztcl::vt new]}
    synopsis {ztcl::vt SUBCOMMAND ?ARG ...?}
    summary {Keeps a terminal screen in memory: feed it the bytes of a program, and read its cells and its text.}
    description {
        The commands of a terminal in memory: the grid of cells, the cursor, the modes, the title, and the scrollback. A script feeds a terminal the bytes of a program and reads back its rows, its cells, and the rows that changed. The parser and the state are libghostty-vt 1.0.2, the terminal library of Ghostty, compiled into the binary.

        Load the module with `package require ztcl::vt`. It needs no capability, reads no file, and starts no process, and its memory counts toward the memory limit of the interpreter. It serves tests of terminal output, a terminal widget, and tools that read the screen of a program on a `ztcl::pty`.

        `new` gives a handle such as `vt0`, and the first argument of each other subcommand is a handle. A handle is valid in the interpreter that made it, until `delete` or the end of the interpreter. The handle is looked up first, so `ztcl::vt size vt99 x` gives the error of the handle, and the name of the subcommand and the count of its arguments are checked after it. The examples of this page have the terminal `$vt` from `ztcl::vt new`. A subcommand has no short form, and `ztcl::vt` with fewer than two arguments, other than `ztcl::vt new`, gives the message of a wrong count of arguments with the list of the subcommands.

        An error of the module has a code that starts with `ZTCL VT`: `HANDLE` for a handle that `new` did not give or that `delete` freed, `SIZE` for a size outside 1 to 4,096, and `SCROLLBACK` for a scrollback outside 0 to 1,000,000. A terminal that needs more memory than the memory limit stops the script with the memory error of the interpreter.
    }
    returns {The result of the subcommand.}
    page modules/vt/
    see {ztcl::pty {ztcl::text width}}
    example {
        set t [ztcl::vt new -size {40 10}]
        ztcl::vt feed $t "hello\r\n\x1b\[1mbold\x1b\[0m"
        set r [list [ztcl::vt rows $t 0 1] [ztcl::vt cursor $t]]
        ztcl::vt delete $t
        set r
    } {{hello bold} {4 1}}
    error {ztcl::vt g $vt} {unknown subcommand "g": must be new, feed, resize, size, cursor, modes, rows, cells, dirty, scrollback, title, bells, or delete} {TCL LOOKUP SUBCOMMAND}
    error {ztcl::vt} {wrong # args: should be "ztcl::vt new|feed|resize|size|cursor|modes|rows|cells|dirty|scrollback|title|bells|delete ?arg ...?"} {TCL WRONGARGS}
    error {ztcl::vt bogus} {wrong # args: should be "ztcl::vt new|feed|resize|size|cursor|modes|rows|cells|dirty|scrollback|title|bells|delete ?arg ...?"} {TCL WRONGARGS}

    subcommand new {
        synopsis {ztcl::vt new ?-size {COLS ROWS}? ?-scrollback LINES?}
        summary {Makes a terminal and gives its handle.}
        description {Makes a terminal with an empty screen and gives its handle, `vt0` for the first one. The cursor starts at row 0, column 0, with the steady block cursor (style 2). Grapheme clusters (mode 2027) are on, also after a reset, so a cluster of UAX #29 is one cell or one wide cell, as in modern terminals; `ESC [?2027l` turns them off. The OSC queries 10 and 11 report black on white. An option that comes again keeps its last value.}
        returns {The handle of the terminal.}
        see {{ztcl::vt delete} {ztcl::vt resize}}
        example {
            set t [ztcl::vt new]
            set r [list [string match vt* $t] [ztcl::vt size $t] [ztcl::vt cursor $t]]
            ztcl::vt delete $t
            set r
        } {1 {80 24} {0 0}}
        error {ztcl::vt new extra} {wrong # args: should be "ztcl::vt new ?-size {cols rows}? ?-scrollback lines?"} {TCL WRONGARGS}
        error {ztcl::vt new -bogus 1} {bad option "-bogus": must be -size or -scrollback} {TCL LOOKUP OPTION}
        error {ztcl::vt new -s {3 3}} {bad option "-s": must be -size or -scrollback} {TCL LOOKUP OPTION}
        option -size {
            value {{COLS ROWS}}
            type {list of two integers}
            default {80 24}
            summary {Gives the count of columns and of rows.}
            description {A list of the count of columns and the count of rows, each 1 to 4,096.}
            example {
                set t [ztcl::vt new -size {20 4}]
                set r [ztcl::vt size $t]
                ztcl::vt delete $t
                set r
            } {20 4}
            error {ztcl::vt new -size {0 5}} {the size 0 is outside 1 to 4096} {ZTCL VT SIZE}
            error {ztcl::vt new -size {5000 5}} {the size 5000 is outside 1 to 4096} {ZTCL VT SIZE}
            error {ztcl::vt new -size 5} {the size must be a list of cols and rows} {ZTCL VT SIZE}
            error {ztcl::vt new -size {a b}} {expected integer but got "a"} NONE
            error {ztcl::vt new -size} {wrong # args: should be "ztcl::vt new ?-size {cols rows}? ?-scrollback lines?"} {TCL WRONGARGS}
        }
        option -scrollback {
            value LINES
            type integer
            default 1,000
            summary {Gives the most lines of the scrollback.}
            description {The most lines that the scrollback keeps, 0 to 1,000,000. libghostty-vt keeps whole pages of rows, so the scrollback can hold more lines than LINES.}
            example {
                set t [ztcl::vt new -size {3 1} -scrollback 0]
                ztcl::vt feed $t "a\r\nb"
                set r [ztcl::vt rows $t]
                ztcl::vt delete $t
                set r
            } b
            error {ztcl::vt new -scrollback -1} {the scrollback -1 is outside 0 to 1000000} {ZTCL VT SCROLLBACK}
            error {ztcl::vt new -scrollback 1000001} {the scrollback 1000001 is outside 0 to 1000000} {ZTCL VT SCROLLBACK}
            error {ztcl::vt new -scrollback x} {expected integer but got "x"} NONE
        }
    }

    subcommand feed {
        synopsis {ztcl::vt feed HANDLE BYTES}
        summary {Feeds the bytes of a program to a terminal and gives its reply.}
        description {
            Feeds the UTF-8 bytes of the string BYTES to the parser. A sequence can end in a later `feed`.

            The result is the reply of the terminal: the bytes that a program gets back for DA (`ESC [c`), DSR (`ESC [5n`, `ESC [6n`), the mode queries, and the OSC color queries. A caller sends the reply to the program. The result is empty when no sequence asks for a reply.

            The bell (BEL) adds 1 to the count of `bells`, and OSC 0 and OSC 2 set the title. A sequence that libghostty-vt does not handle has no effect.
        }
        returns {The reply of the terminal, or an empty string.}
        see {{ztcl::vt rows} {ztcl::vt cells}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        argument BYTES {
            type string
            summary {The output of a program.}
        }
        example {
            set t [ztcl::vt new -size {20 4}]
            set r [ztcl::vt feed $t "abc\x1b\[6n"]
            ztcl::vt delete $t
            string map [list \x1b ESC] $r
        } {ESC[1;4R}
        example {
            set t [ztcl::vt new]
            set r [ztcl::vt feed $t "\x1b\[c\x1b\[5n"]
            ztcl::vt delete $t
            string map [list \x1b ESC] $r
        } {ESC[?62;22cESC[0n}
        example {
            set t [ztcl::vt new]
            set r [ztcl::vt feed $t "\x1b\]11;?\x07"]
            ztcl::vt delete $t
            string map [list \x1b ESC \x07 BEL] $r
        } {ESC]11;rgb:ffff/ffff/ffffBEL}
        example {
            set t [ztcl::vt new]
            ztcl::vt feed $t "a\x1b\["
            ztcl::vt feed $t "1mb"
            set r [lindex [ztcl::vt cells $t 0] 0 1]
            ztcl::vt delete $t
            set r
        } {b 1 {} {} bold}
        error {ztcl::vt feed vt99 x} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt feed $vt} {wrong # args: should be "ztcl::vt feed handle bytes"} {TCL WRONGARGS}
    }

    subcommand resize {
        synopsis {ztcl::vt resize HANDLE COLS ROWS}
        summary {Changes the size of a terminal.}
        description {Changes the size to COLS columns and ROWS rows, each 1 to 4,096. The text of the primary screen reflows to the new width, and the rows above the cursor go to the scrollback when the screen gets shorter. Each row is then dirty.}
        returns {An empty string.}
        see {{ztcl::vt size} {ztcl::vt new}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        argument COLS {
            type integer
            summary {The new count of columns.}
        }
        argument ROWS {
            type integer
            summary {The new count of rows.}
        }
        example {
            set t [ztcl::vt new -size {10 2}]
            ztcl::vt feed $t "one\r\ntwo\r\nthree"
            ztcl::vt resize $t 5 2
            set r [list [ztcl::vt size $t] [ztcl::vt rows $t] [ztcl::vt scrollback $t]]
            ztcl::vt delete $t
            set r
        } {{5 2} {three {}} 2}
        error {ztcl::vt resize $vt 0 2} {the size 0 is outside 1 to 4096} {ZTCL VT SIZE}
        error {ztcl::vt resize $vt a 2} {expected integer but got "a"} NONE
        error {ztcl::vt resize $vt 10} {wrong # args: should be "ztcl::vt resize handle cols rows"} {TCL WRONGARGS}
    }

    subcommand size {
        synopsis {ztcl::vt size HANDLE}
        summary {Gives the count of columns and of rows of a terminal.}
        description {Gives the list `COLS ROWS`.}
        returns {A list of two integers.}
        see {{ztcl::vt resize}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new -size {20 4}]
            set r [ztcl::vt size $t]
            ztcl::vt delete $t
            set r
        } {20 4}
        error {ztcl::vt size vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt size $vt x} {wrong # args: should be "ztcl::vt size handle"} {TCL WRONGARGS}
    }

    subcommand cursor {
        synopsis {ztcl::vt cursor HANDLE}
        summary {Gives the place of the cursor.}
        description {Gives the list `X Y` of the cursor in the active area, from 0.}
        returns {A list of two integers.}
        see {{ztcl::vt modes}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new]
            ztcl::vt feed $t "\x1b\[3;5H"
            set r [ztcl::vt cursor $t]
            ztcl::vt delete $t
            set r
        } {4 2}
        error {ztcl::vt cursor vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt cursor $vt x} {wrong # args: should be "ztcl::vt cursor handle"} {TCL WRONGARGS}
    }

    subcommand modes {
        synopsis {ztcl::vt modes HANDLE}
        summary {Gives a dict of the modes of a terminal.}
        description {
            Gives a dict with these keys:

            - `cursor_keys_app`: 1 after DECCKM (`ESC [?1h`);
            - `keypad_app`: 1 after DECNKM (`ESC [?66h`);
            - `cursor_visible`: 0 after `ESC [?25l`;
            - `bracketed_paste`: 1 after `ESC [?2004h`;
            - `focus_events`: 1 after `ESC [?1004h`;
            - `mouse_sgr`: 1 after `ESC [?1006h`;
            - `alt_screen`: 1 while the alternate screen is active (`ESC [?1049h`);
            - `mouse`: `none`, `x10`, `normal`, `button`, or `any` (modes 9, 1000, 1002, and 1003);
            - `cursor_style`: the DECSCUSR number, 1 or 2 for a block, 3 or 4 for an underline, 5 or 6 for a bar. An odd number blinks.
        }
        returns {A dict.}
        see {{ztcl::vt cursor}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new]
            set r [ztcl::vt modes $t]
            ztcl::vt delete $t
            set r
        } {cursor_keys_app 0 keypad_app 0 cursor_visible 1 bracketed_paste 0 focus_events 0 mouse_sgr 0 alt_screen 0 mouse none cursor_style 2}
        example {
            set t [ztcl::vt new]
            ztcl::vt feed $t "\x1b\[?1049h\x1b\[?1000h\x1b\[?1006h"
            set m [ztcl::vt modes $t]
            ztcl::vt delete $t
            list [dict get $m alt_screen] [dict get $m mouse] [dict get $m mouse_sgr]
        } {1 normal 1}
        example {
            set t [ztcl::vt new]
            ztcl::vt feed $t "\x1b\[?25l\x1b\[4 q"
            set m [ztcl::vt modes $t]
            ztcl::vt delete $t
            list [dict get $m cursor_visible] [dict get $m cursor_style]
        } {0 4}
        error {ztcl::vt modes vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt modes $vt x} {wrong # args: should be "ztcl::vt modes handle"} {TCL WRONGARGS}
    }

    subcommand rows {
        synopsis {ztcl::vt rows HANDLE ?FIRST? ?LAST?}
        summary {Gives the text of the rows of a terminal.}
        description {Gives a list with the text of each row from FIRST to LAST, with the blanks at the end of each row removed. Row 0 is the top of the active area, and a negative row is a line of the scrollback: -1 is its last line. With no index the list has each row of the active area, and with one index it has that row. An index outside the screen is clamped to the first or the last row, and a FIRST after LAST gives an empty list.}
        returns {A list of strings.}
        see {{ztcl::vt cells} {ztcl::vt scrollback}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        argument FIRST {
            type integer
            optional
            summary {The first row.}
        }
        argument LAST {
            type integer
            optional
            summary {The last row.}
        }
        example {
            set t [ztcl::vt new -size {10 2}]
            ztcl::vt feed $t "one\r\ntwo\r\nthree"
            set r [list [ztcl::vt rows $t] [ztcl::vt rows $t -1 1] [ztcl::vt rows $t 0]]
            ztcl::vt delete $t
            set r
        } {{two three} {one two three} two}
        example {
            set t [ztcl::vt new -size {10 2}]
            ztcl::vt feed $t "one\r\ntwo"
            set r [list [ztcl::vt rows $t -100 100] [ztcl::vt rows $t 1 0]]
            ztcl::vt delete $t
            set r
        } {{one two} {}}
        error {ztcl::vt rows vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt rows $vt 0 1 2} {wrong # args: should be "ztcl::vt rows|cells handle ?first? ?last?"} {TCL WRONGARGS}
        error {ztcl::vt rows $vt end} {expected integer but got "end"} NONE
    }

    subcommand cells {
        synopsis {ztcl::vt cells HANDLE ?FIRST? ?LAST?}
        summary {Gives the cells of the rows of a terminal.}
        description {
            Gives one list for each row from FIRST to LAST, with the same indexes as `rows`. Each row is a list of COLS cells, and a cell is the list `TEXT WIDTH FG BG ATTRS`:

            - TEXT is the grapheme cluster of the cell, such as `e` with U+0301 or an emoji ZWJ sequence, or empty for a cell with no character. A cell keeps the first 8 code points of a cluster.
            - WIDTH is 1, 2 for a wide character, or 0 for the cell after a wide character.
            - FG and BG are empty for the default color, an index of the 256-color palette, or `#rrggbb`.
            - ATTRS lists `bold`, `dim`, `italic`, `underline`, `blink`, `inverse`, `hidden`, and `strike`.
        }
        returns {A list of rows, each a list of cells.}
        see {{ztcl::vt rows} {ztcl::text width}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        argument FIRST {
            type integer
            optional
            summary {The first row.}
        }
        argument LAST {
            type integer
            optional
            summary {The last row.}
        }
        example {
            set t [ztcl::vt new -size {4 1}]
            ztcl::vt feed $t "\x1b\[1;31mA\x1b\[0m\x1b\[48;2;0;128;255mB\x1b\[0m中"
            set r [lindex [ztcl::vt cells $t 0] 0]
            ztcl::vt delete $t
            lrange $r 0 1
        } {{A 1 1 {} bold} {B 1 {} #0080ff {}}}
        example {
            set t [ztcl::vt new -size {4 1}]
            ztcl::vt feed $t "ab中"
            set r [lindex [ztcl::vt cells $t 0] 0]
            ztcl::vt delete $t
            list [lindex $r 2 1] [lindex $r 3]
        } {2 {{} 0 {} {} {}}}
        example {
            set t [ztcl::vt new -size {3 1}]
            ztcl::vt feed $t "\x1b\[38;5;200;2;3;4;5;7;8;9mq"
            set r [lindex [ztcl::vt cells $t 0] 0 0]
            ztcl::vt delete $t
            set r
        } {q 1 200 {} {dim italic underline blink inverse hidden strike}}
        error {ztcl::vt cells vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt cells $vt 0 0 0} {wrong # args: should be "ztcl::vt rows|cells handle ?first? ?last?"} {TCL WRONGARGS}
    }

    subcommand dirty {
        synopsis {ztcl::vt dirty HANDLE}
        summary {Gives the rows that changed since the last call.}
        description {Gives the rows of the active area that changed since the last call of `dirty`, in order. The first call gives each row. A change of the size or of the colors gives each row. A move of the cursor changes the row that it leaves and the row that it goes to.}
        returns {A list of row indexes.}
        see {{ztcl::vt rows} {ztcl::vt cells}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new -size {10 3}]
            set a [ztcl::vt dirty $t]
            ztcl::vt feed $t "\x1b\[3;1Hx"
            set r [list $a [ztcl::vt dirty $t] [ztcl::vt dirty $t]]
            ztcl::vt delete $t
            set r
        } {{0 1 2} {0 2} {}}
        error {ztcl::vt dirty vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt dirty $vt x} {wrong # args: should be "ztcl::vt dirty handle"} {TCL WRONGARGS}
    }

    subcommand scrollback {
        synopsis {ztcl::vt scrollback HANDLE}
        summary {Gives the count of lines in the scrollback.}
        description {Gives the count of lines in the scrollback. The alternate screen has no scrollback.}
        returns {An integer.}
        see {{ztcl::vt rows}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new -size {10 2}]
            ztcl::vt feed $t "one\r\ntwo\r\nthree"
            set r [ztcl::vt scrollback $t]
            ztcl::vt delete $t
            set r
        } 1
        error {ztcl::vt scrollback vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt scrollback $vt x} {wrong # args: should be "ztcl::vt scrollback handle"} {TCL WRONGARGS}
    }

    subcommand title {
        synopsis {ztcl::vt title HANDLE}
        summary {Gives the title of a terminal.}
        description {Gives the title from the last OSC 0 or OSC 2, or an empty string. The OSC can end with BEL or with ST (`ESC \`).}
        returns {The title.}
        see {{ztcl::vt feed}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new]
            set a [ztcl::vt title $t]
            ztcl::vt feed $t "\x1b\]2;Build\x07"
            set r [list $a [ztcl::vt title $t]]
            ztcl::vt delete $t
            set r
        } {{} Build}
        error {ztcl::vt title vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt title $vt x} {wrong # args: should be "ztcl::vt title handle"} {TCL WRONGARGS}
    }

    subcommand bells {
        synopsis {ztcl::vt bells HANDLE}
        summary {Gives the count of bells since the terminal was made.}
        description {Gives the count of BEL characters since `new`. A BEL that ends an OSC is no bell.}
        returns {An integer.}
        see {{ztcl::vt feed}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new]
            ztcl::vt feed $t "a\x07b\x07\x1b\]2;T\x07"
            set r [ztcl::vt bells $t]
            ztcl::vt delete $t
            set r
        } 2
        error {ztcl::vt bells vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt bells $vt x} {wrong # args: should be "ztcl::vt bells handle"} {TCL WRONGARGS}
    }

    subcommand delete {
        synopsis {ztcl::vt delete HANDLE}
        summary {Frees a terminal.}
        description {Frees the terminal, and the handle is then invalid. The interpreter frees each terminal that is left when it ends or when an embedder calls `Interp.reset`.}
        returns {An empty string.}
        see {{ztcl::vt new}}
        argument HANDLE {
            type handle
            summary {A handle from `new`.}
        }
        example {
            set t [ztcl::vt new]
            ztcl::vt delete $t
            catch {ztcl::vt size $t}
        } 1
        error {ztcl::vt delete vt99} {can not find terminal "vt99"} {ZTCL VT HANDLE}
        error {ztcl::vt delete $vt $vt} {wrong # args: should be "ztcl::vt delete handle"} {TCL WRONGARGS}
    }
}
