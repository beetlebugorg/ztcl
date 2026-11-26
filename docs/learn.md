# Learn Tcl

This page teaches Tcl from the start. Each section has examples. A live example runs in the page: edit its code, and its output changes. The shell below has the state of the page: the variables, the procs, and the files of the examples. Type a command in the shell and press Enter. A helper makes a command from a small form, and its button puts the command on the line of the shell. In the shell, Alt-I shows the last result as a tree.

If you know Tcl already, [Coming from tclsh](language.md) lists what ztcl does differently.

<!-- shell -->
```tcl
set s "the cat sat on the mat"
set words [split $s]
set nums {12 5 40 7}
set user [dict create name Ada lang Tcl year 1843]
set rooms {
    hall    {text "a cold hall"     exits {north library}}
    library {text "a dusty library" exits {south hall} item lamp}
}
set here hall
set bag {}
proc look {} {
    global rooms here
    set room [dict get $rooms $here]
    puts "You are in [dict get $room text]."
    if {[dict exists $room item]} { puts "You see a [dict get $room item]." }
    puts "Exits: [dict keys [dict get $room exits]]"
}
proc go {dir} {
    global rooms here
    set exits [dict get $rooms $here exits]
    if {![dict exists $exits $dir]} { return "You cannot go $dir." }
    set here [dict get $exits $dir]
    look
}
namespace eval counter {
    variable n 0
    proc next {} { variable n; incr n }
    namespace export next
    namespace ensemble create
}
oo::class create Account {
    variable balance
    constructor {} { set balance 0 }
    method deposit {n} { incr balance $n; my show }
    method show {} { return "balance $balance" }
}
proc take {thing} {
    global rooms here bag
    if {[dict get $rooms $here item] ne $thing} { return "No $thing here." }
    lappend bag $thing
    dict unset rooms $here item
    return "You take the $thing."
}
```

<!-- file: notes.txt -->
```text
buy milk
fix the bike
call Ada
```

## Words and substitution

A Tcl script is a list of commands. A command is a list of words, and the first word is the name of the command. Tcl does three substitutions on a word before it calls the command:

- `$name` becomes the value of a variable.
- `[script]` becomes the result of the script.
- A backslash escapes the next character, and `\n` is a newline.

Double quotes make one word that has spaces, and the substitutions still happen in it. Braces make one word with no substitution.

<!-- run -->
```tcl
set name Ada
puts "Hello, $name. 2 + 3 is [expr {2 + 3}]."
puts {Hello, $name. 2 + 3 is [expr {2 + 3}].}
```

```text
Hello, Ada. 2 + 3 is 5.
Hello, $name. 2 + 3 is [expr {2 + 3}].
```

This rule is all of the syntax. `if`, `proc`, and `while` are commands like `puts`, and their bodies are words in braces. The command gets the body as text and runs it when it is time.

## Variables and numbers

`set` gives a value to a variable, and `set` with one word gives the value back. Each value is a string. A command that needs a number reads the string as a number. `incr` adds to an integer variable.

`expr` computes a math expression. Put the expression in braces. Then `expr` does its own substitution, and the expression is compiled once.

<!-- run -->
```tcl
set width 7
set height 3
incr width
puts [expr {$width * $height}]
puts [expr {10 / 4}]
puts [expr {10 / 4.0}]
puts [expr {2 ** 100}]
```

```text
24
2
2.5
1267650600228229401496703205376
```

An integer divided by an integer gives an integer. Integers have no fixed size.

<!-- helper: expr -->
```tcl
# height: 320
helper::form
helper::row Expression [ttk::entry .f.e -textvariable e -font TkFixedFont]
ttk::frame .f.keys
set n 0
foreach k {7 8 9 / sqrt( 4 5 6 * abs( 1 2 3 - pow( 0 . , + ) ( ** % ?: Clear} {
    if {$k eq "Clear"} {
        set do {set e ""}
    } elseif {$k eq "?:"} {
        set do {append e " ? 1 : 0"}
    } else {
        set do [list append e $k]
    }
    ttk::button .f.keys.b$n -text $k -width 5 -command $do
    grid .f.keys.b$n -row [expr {$n / 5}] -column [expr {$n % 5}] -padx 1 -pady 1
    incr n
}
helper::row "" .f.keys
helper::footer 1
set e "2 ** 10 + sqrt(16)"
helper::watch {helper::show [list expr $e]} e
```

## Lists

A list is a string with words that are split by spaces. Braces group a word that has spaces. `list` makes a list with the right braces, and `lindex`, `llength`, `lappend`, `lrange`, and `lsort` work on lists. `foreach` runs a body for each element.

<!-- run -->
```tcl
set fruit [list apple "star fruit" fig]
puts [llength $fruit]
puts [lindex $fruit 1]
lappend fruit kiwi
foreach f [lsort $fruit] { puts "- $f" }
```

```text
3
star fruit
- apple
- fig
- kiwi
- star fruit
```

`lsort` sorts as text by default. With `-integer` it sorts numbers, and `-dictionary` sorts text with numbers in it, so `a9` comes before `a10`.

<!-- helper: lsort -->
```tcl
# height: 236
helper::form
helper::row List [ttk::entry .f.l -textvariable l]
helper::row Compare [ttk::combobox .f.c -textvariable how -state readonly -values {-ascii -dictionary -integer -real}]
ttk::frame .f.o
foreach {flag v} {-decreasing dec -unique uniq -nocase nocase} {
    ttk::checkbutton .f.o.$v -text $flag -variable $v
    pack .f.o.$v -side left -padx {0 12}
}
helper::row "" .f.o
helper::footer 1
set l {a10 B2 a9 b2 a10}
set how -dictionary
lassign {0 0 0} dec uniq nocase
proc build {} {
    set cmd [list lsort $::how]
    foreach {flag v} {-decreasing dec -unique uniq -nocase nocase} {
        if {[set ::$v]} { lappend cmd $flag }
    }
    helper::show [lappend cmd $::l]
}
helper::watch build l how dec uniq nocase
```

## Dicts

A dict is a list of keys and values. `dict get` reads a value, and `dict set` changes a value in a variable. `dict for` runs a body for each key and value. A dict keeps the order of its keys.

<!-- run -->
```tcl
set user [dict create name Ada lang Tcl]
dict set user year 1843
puts [dict get $user name]
dict for {k v} $user { puts "$k = $v" }
```

```text
Ada
name = Ada
lang = Tcl
year = 1843
```

The helper below uses the commands that give a new dict and do not change a variable: `dict replace`, `dict remove`, and `dict merge`. The table shows the dict of the result.

<!-- helper: dict -->
```tcl
# height: 402
helper::form
helper::row Dict [ttk::entry .f.d -textvariable d]
helper::row Command [ttk::combobox .f.op -textvariable op -state readonly -values {get replace remove exists keys}]
helper::row Key [ttk::entry .f.k -textvariable key]
helper::row Value [ttk::entry .f.v -textvariable val]
ttk::treeview .f.t -columns {key value} -show headings -height 4
.f.t heading key -text Key
.f.t heading value -text Value
helper::row Table .f.t
helper::footer 1
set d {name Ada lang Tcl}
set op replace
set key year
set val 1843
proc build {} {
    switch -- $::op {
        replace { set cmd [list dict replace $::d $::key $::val] }
        keys { set cmd [list dict keys $::d] }
        default { set cmd [list dict $::op $::d $::key] }
    }
    helper::show $cmd
    helper::run $cmd table
}
proc table {ok r} {
    .f.t delete [.f.t children {}]
    if {!$ok || $::op ni {replace remove}} { set r $::d }
    if {[catch {dict size $r}]} return
    dict for {k v} $r { .f.t insert {} end -values [list $k $v] }
}
helper::watch build d op key val
```

## Strings

`string` has the commands for text: `string length`, `string range`, `string toupper`, `string first`, and more. `split` makes a list from a string, and `join` makes a string from a list. `format` works as `printf` does.

<!-- run -->
```tcl
set s "the cat sat on the mat"
puts [string length $s]
puts [string toupper [string range $s 4 6]]
puts [join [lreverse [split $s]] " "]
puts [format "%-6s|%5.2f|" pi 3.14159]
```

```text
22
CAT
mat the on sat cat the
pi    | 3.14|
```

`string map` replaces each key of a list of pairs with its value. It reads the string once, from left to right, and at each place it tries the keys in their order.

<!-- helper: string map -->
```tcl
# height: 234
helper::form
helper::row String [ttk::entry .f.s -textvariable s]
helper::row Pairs [ttk::entry .f.m -textvariable map]
helper::row "" [ttk::checkbutton .f.n -text -nocase -variable nocase]
helper::footer
set s "the cat sat on the mat"
set map {cat dog mat rug}
set nocase 0
proc build {} {
    set cmd [list string map]
    if {$::nocase} { lappend cmd -nocase }
    helper::show [lappend cmd $::map $::s]
}
helper::watch build s map nocase
```

`regexp` finds a pattern in a string. With `-inline` it gives the match and the text of each group in parentheses. With `-all` it finds each match. `regsub` replaces the matches.

<!-- run -->
```tcl
puts [regexp -inline {(\d+)-(\d+)} "pages 12-40"]
puts [regexp -all -inline {\w+@\w+} "ada@tcl and bob@zig"]
puts [regsub -all {\s+} "a   b  c" " "]
```

```text
12-40 12 40
ada@tcl bob@zig
a b c
```

The helper marks each match in the string, and each group in a second color.

<!-- helper: regexp -->
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
set pat {(\w+)@(\w+)}
set str "ada@tcl and bob@zig"
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

## Control flow

`if`, `while`, `for`, `foreach`, and `switch` are commands. Their conditions are expressions, as in `expr`. `break` and `continue` work in each loop.

<!-- run -->
```tcl
foreach n {3 8 15} {
    if {$n % 15 == 0} {
        puts "$n fizzbuzz"
    } elseif {$n % 3 == 0} {
        puts "$n fizz"
    } else {
        puts $n
    }
}
switch -glob -- "photo.png" {
    *.png - *.jpg { puts image }
    default { puts other }
}
```

```text
3 fizz
8
15 fizzbuzz
image
```

## Procs

`proc` makes a new command from a name, a list of arguments, and a body. An argument with a default value is a list of two words. The last argument `args` gets each other word as a list. A proc returns the result of its last command, or the value of `return`.

<!-- run -->
```tcl
proc greet {name {greeting Hello}} {
    return "$greeting, $name!"
}
proc sum {args} {
    set total 0
    foreach n $args { incr total $n }
    return $total
}
puts [greet Ada]
puts [greet Bob Hi]
puts [sum 1 2 3 4]
```

```text
Hello, Ada!
Hi, Bob!
10
```

The variables of a proc are local. `global` links a name to a variable of the top level. `upvar` links a name to a variable of the caller, so a proc can change a variable that the caller names. `uplevel` runs a script in the frame of the caller.

<!-- run -->
```tcl
proc double {varName} {
    upvar 1 $varName v
    set v [expr {$v * 2}]
}
set x 21
double x
puts $x
```

```text
42
```

The shell has a small game in its procs: type `look`, `go north`, and `take lamp`. The game keeps the map in the dict `rooms`, and each command is a proc. Type `info body go` to see the code, or change a proc and play again.

The helper below makes a proc from its three words and calls it with the words of "Call with". The result is the result of the call. The button puts the `proc` command into the shell, and then the reader can call the new command.

<!-- helper: proc -->
```tcl
# height: 280
helper::form
helper::row Name [ttk::entry .f.n -textvariable name -font TkFixedFont]
helper::row Arguments [ttk::entry .f.a -textvariable params -font TkFixedFont]
helper::row Body [ttk::entry .f.b -textvariable body -font TkFixedFont]
helper::row "Call with" [ttk::entry .f.c -textvariable call -font TkFixedFont]
helper::footer 2
set name greet
set params {name {greeting Hello}}
set body {return "$greeting, $name!"}
set call Ada
proc build {} {
    set helper::cmd [list proc $::name $::params $::body]
    helper::run "[list apply [list $::params $::body]] $::call" helper::result
}
helper::watch build name params body call
```

## Namespaces

A namespace keeps a group of commands and variables apart from other names. `namespace eval` runs a script in a namespace, and `::` joins the names. `namespace ensemble create` makes a command with subcommands, as `string` and `dict` are.

<!-- run -->
```tcl
namespace eval counter {
    variable n 0
    proc next {} { variable n; incr n }
    namespace export next
    namespace ensemble create
}
counter next
puts [counter next]
puts $counter::n
```

```text
2
2
```

The namespace `counter` is in the shell too: type `counter next`. The helper below lists the children, the commands, or the variables of a namespace. The list of namespaces comes from the shell when the helper starts.

<!-- helper: namespace -->
```tcl
# height: 230
helper::form
helper::row Namespace [ttk::combobox .f.ns -textvariable ns -values {:: ::counter ::tcl ::oo}]
helper::row Show [ttk::combobox .f.what -textvariable what -state readonly -values {children commands vars}]
helper::footer 3
set ns ::counter
set what commands
proc build {} {
    set pattern [string trimright $::ns :]::*
    switch -- $::what {
        children { helper::show [list namespace children $::ns] }
        commands { helper::show [list info commands $pattern] }
        vars { helper::show [list info vars $pattern] }
    }
}
helper::watch build ns what
helper::run {namespace children ::} {apply {{ok r} { if {$ok} { .f.ns configure -values [linsert $r 0 ::] } }}}
```

## Errors

`error` stops a script with a message. `catch` runs a script and gives 1 for an error. `try` runs a script and has a branch for each outcome, and `finally` always runs.

<!-- run -->
```tcl
proc half {n} {
    if {$n % 2} { error "$n is odd" }
    return [expr {$n / 2}]
}
try {
    puts [half 10]
    puts [half 7]
} on error {msg} {
    puts "error: $msg"
} finally {
    puts done
}
```

```text
5
error: 7 is odd
done
```

`catch` with two variable names gives the message and a dict of options. The option `-errorcode` is a list that a program can test, and `-errorline` is the line of the error in the script. The helper below runs a script with `catch` and shows the code, the message, and the two options. It runs the script at the top level of the shell, so `$user` and the other variables of the page work.

<!-- helper: catch -->
```tcl
# height: 215
helper::form
helper::row Script [ttk::entry .f.s -textvariable script -font TkFixedFont]
helper::footer 4
set script {expr {[lindex $nums 0] / 0}}
proc build {} {
    set helper::cmd [list catch $::script msg opts]
    helper::run [list apply {{s} {
        set code [catch {uplevel #0 $s} msg opts]
        set out "code $code\nmessage $msg"
        if {$code == 1} {
            append out "\n-errorcode [dict get $opts -errorcode]\n-errorline [dict get $opts -errorline]"
        }
        return $out
    }} $::script] helper::result
}
helper::watch build script
```

## Files

`open` gives a channel. `gets` reads one line, `read` reads all of it, and `puts` with a channel writes to it. `close` closes the channel. The shell of this page has the read-only file `notes.txt` from the top of the page. In the shell, type `set f [open notes.txt]` and then `gets $f`.

<!-- run: --root . --allow file,channels -->
```tcl
set f [open todo.txt w]
puts $f "buy milk\nfix the bike"
close $f
set f [open todo.txt]
while {[gets $f line] >= 0} { puts "* $line" }
close $f
```

```text
* buy milk
* fix the bike
```

In ztcl, files and channels are a capability. The `ztcl` program has them, and an app that embeds ztcl turns them on or keeps them off. [Limits and capabilities](limits.md) tells how.

The helper below reads `notes.txt` in four ways. The command opens the file, reads it, and closes it. The helper runs the command in a lambda, so the variables `f` and `text` stay local until the reader puts the command into the shell.

<!-- helper: read a file -->
```tcl
# height: 195
helper::form
helper::row Read [ttk::combobox .f.how -textvariable how -state readonly -values {read "read -nonewline" gets "read 8"}]
helper::footer 3
set how gets
proc build {} {
    switch -- $::how {
        read { set body {read $f} }
        "read -nonewline" { set body {read -nonewline $f} }
        gets { set body {gets $f} }
        default { set body {read $f 8} }
    }
    set cmd "set f \[open notes.txt\]; set text \[$body\]; close \$f; set text"
    set helper::cmd $cmd
    helper::run [list apply [list {} $cmd]] helper::result
}
helper::watch build how
```

## Events

`after` runs a script later, and `vwait` runs the event loop until a variable changes. A script that waits for a timer, a channel, or a socket uses the event loop. The event loop is a capability too, and the shell of this page has no event loop.

<!-- run: --allow event -->
```tcl
set n 0
proc tick {} {
    global n
    puts "tick [incr n]"
    if {$n < 3} { after 100 tick } else { set ::done 1 }
}
after 100 tick
vwait done
```

```text
tick 1
tick 2
tick 3
```

## Objects

`oo::class create` makes a class. `constructor` and `method` define its code, and `my` calls a method of the same object. `new` makes an object, and the object is a command.

<!-- run -->
```tcl
oo::class create Account {
    variable balance
    constructor {} { set balance 0 }
    method deposit {n} { incr balance $n; my show }
    method show {} { return "balance $balance" }
}
set a [Account new]
puts [$a deposit 30]
puts [$a deposit 12]
```

```text
balance 30
balance 42
```

The class `Account` is in the shell too: type `set a [Account new]` and then `$a deposit 5`. `info class` shows the parts of a class, and the helper below builds its subcommands.

<!-- helper: info class -->
```tcl
# height: 230
helper::form
helper::row Class [ttk::combobox .f.c -textvariable cls -values Account]
helper::row Show [ttk::combobox .f.what -textvariable what -state readonly -values {methods variables "definition deposit" constructor instances}]
helper::footer 3
set cls Account
set what methods
helper::watch {helper::show "info class $what [list $cls]"} cls what
```

## Coroutines

A coroutine is a proc that can stop in the middle with `yield` and go on at the next call. Each call gives the next value. The traffic light below never ends, and each call gives its next state.

The WebAssembly build of ztcl has no `coroutine`, so this example does not run in the page, and the shell of the page has no coroutines. [Targets](targets.md) lists the features of each target.

<!-- run: native -->
```tcl
proc light {} {
    yield
    while 1 {
        foreach color {green yellow red} { yield $color }
    }
}
coroutine next light
foreach i {1 2 3 4} { puts [next] }
```

```text
green
yellow
red
green
```

## Lambdas

`apply` runs an anonymous proc: a list of the arguments and the body. `lmap` makes a new list from the results of a body. Together they work as `map` does in other languages.

<!-- run -->
```tcl
set square {{x} { expr {$x * $x} }}
puts [apply $square 9]
puts [lmap n {1 2 3 4} { apply $square $n }]
puts [lsort -command {apply {{a b} { expr {[string length $a] - [string length $b]} }}} {ccc a bb}]
```

```text
81
1 4 9 16
a bb ccc
```

## Mistakes to avoid

- **Put each expression in braces.** `expr {$a + $b}` is safe and fast. `expr $a + $b` substitutes the values first, and then `expr` reads them a second time as code.
- **A comment is a command.** `#` starts a comment only at the start of a command. After a command on the same line, write `;#`. A brace in a comment counts for the braces of the body.
- **Give the name of a variable to a command that changes it.** `lappend fruit kiwi` and `incr n` take the name of a variable. `$fruit` gives its value.
- **From Python and JavaScript:** no operator works outside `expr`, so `set x 1 + 2` is an error. Write `set x [expr {1 + 2}]`. A list is a string, so `[]` makes a substitution and does not make a list.
- **From the shell:** a variable in double quotes stays one word, and its spaces do not split it. Use `{*}$args` to give each element of a list as its own word.
