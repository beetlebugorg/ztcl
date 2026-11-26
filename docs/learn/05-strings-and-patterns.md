# Strings and patterns

`string` has the commands for text, `split` and `join` go between strings and lists, and `regexp` finds patterns. This lesson gives `jot` tags: a word such as `#home` in the text of a note.

<!-- checkpoint -->
```tcl
set text "buy milk #home #shop"
```

## The string commands

[`string length $text`](run: "20") counts characters, and [`string first milk $text`](run: "4") finds text. [`string range $text 4 7`](run: "milk") cuts a part, and [`string map {#home @home} $text`](run: "buy milk @home #shop") replaces text. [`string match "*#home*" $text`](run: "1") matches a glob pattern, as a shell does with file names.

[`split "a,b,,c" ,`](run: "a b {} c") makes a list, with an empty element between the two commas. [`join {a b c} -`](run: "a-b-c") makes a string. `format` works as `printf` does: [`format "%3d. %s" 7 milk`](run: "  7. milk").

`string is` checks the type of a value. Add `-strict`, because an empty string passes each check without it: [`string is integer -strict 42abc`](run: "0").

## regexp

`regexp` finds a pattern. With `-inline` it gives the match and each group in parentheses, and with `-all` it finds each match. [`regexp -all -inline {#\w+} $text`](run: "{#home} #shop") gives the tags of the note. The braces around `#home` are list format: an element that starts with `#` gets braces, so that the list does not read as a comment. `regsub` replaces matches: [`regsub -all {#(\w+)} $text {[\1]}`](run: "buy milk [home] [shop]").

Use the tool to build a pattern. It marks each match, and each group in a second color.

<!-- helper: Build a regexp | Type a pattern and a string, and see each match, with its groups in a second color. -->
```tcl
# height: 284
helper::form
helper::row Pattern [ttk::entry .f.p -textvariable pat -font TkFixedFont]
helper::row String [ttk::entry .f.s -textvariable str]
ttk::frame .f.o
foreach {flag v} {-all all -nocase nocase} {
    ttk::checkbutton .f.o.$v -text $flag -variable $v
    pack .f.o.$v -side left -padx {0 12}
}
helper::row "" .f.o
text .f.hl -height 1 -font TkFixedFont -relief solid -borderwidth 1
.f.hl tag configure match -background #ffe08a -foreground #1d1a33
.f.hl tag configure group -background #9fd8ff -foreground #1d1a33
helper::row Matches .f.hl
helper::footer 1
set pat {#(\w+)}
set str "buy milk #home #shop"
set all 1
set nocase 0
proc build {} {
    set opts {}
    if {$::all} { lappend opts -all }
    if {$::nocase} { lappend opts -nocase }
    helper::show [list regexp {*}$opts -inline $::pat $::str]
    helper::run [list list [lindex [regexp -about $::pat] 0] [regexp {*}$opts -inline -indices $::pat $::str]] mark
}
proc mark {ok r} {
    .f.hl configure -state normal
    .f.hl delete 1.0 end
    .f.hl insert end $::str
    if {$ok} {
        lassign $r groups spans
        set i 0
        foreach span $spans {
            lassign $span a b
            if {$a >= 0 && $b >= $a} {
                .f.hl tag add [expr {$i % ($groups + 1) ? "group" : "match"}] "1.0 + $a chars" "1.0 + [incr b] chars"
            }
            incr i
        }
    }
    .f.hl configure -state disabled
}
helper::watch build pat str all nocase
```


## Two traps

A pattern goes in braces. In quotes, Tcl changes `\d` to `d` before `regexp` gets it: [`regexp "\d+" "abc 42"`](run: "0") finds no digits, and [`regexp {\d+} "abc 42"`](run: "1") finds them. A `[` in quotes also runs a command.

A pattern with no anchors matches a part of the string. [`regexp {\d+} "42abc"`](run: "1") is true. A check of a whole value needs `^` and `$`: [`regexp {^\d+$} "42abc"`](run: "0").

## Reading code an agent wrote

- Each pattern of `regexp` and `regsub` is in braces.
- A check of input has `^` and `$`, or uses `string is ... -strict`.
- `split` on a string with two separators in a row gives an empty element. Look for code that skips it.
- `string match` uses glob patterns, and `regexp` uses regular expressions. `*` has a different meaning in each.

## Ask an agent

> Write a Tcl proc that gives the tags of a note: each word that starts with `#`, without the `#`, in lowercase, with no duplicates. Use `regexp -all -inline` with the pattern in braces.

## Try this

- Change the pattern of the tool to `#(\w+)$`, and see which tag matches.
- Make `format` print a table row: `format "%-10s %5d" milk 3`.
- Find what `split "a  b"` gives for two spaces.
