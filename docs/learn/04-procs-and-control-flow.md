# Procs and control flow

`proc` makes a command. `if`, `foreach`, and `while` are commands too, and their bodies are words in braces. This lesson gives `jot` the commands `add`, `show`, and `done`, and ends "Read Tcl in 15 minutes".

<!-- checkpoint -->
```tcl
set notes [list [dict create text "buy milk" done 1] [dict create text "fix the bike" done 0]]
```

## The procs of jot

Run the box. It makes three procs in the shell.

<!-- define -->
```tcl
proc add {text} {
    global notes
    lappend notes [dict create text $text done 0]
    return [llength $notes]
}
proc show {} {
    global notes
    set i 0
    foreach n $notes {
        incr i
        set mark [expr {[dict get $n done] ? "x" : " "}]
        puts "$i. \[$mark\] [dict get $n text]"
    }
}
proc done {i} {
    global notes
    set k [expr {$i - 1}]
    if {$k < 0 || $k >= [llength $notes]} {
        return -code error "no note $i"
    }
    lset notes $k [dict replace [lindex $notes $k] done 1]
    return [lindex $notes $k]
}
```

Now use them: [`add "call Ada"`](run: "3"), [`show`](run: ""), and [`done 3`](run: "text {call Ada} done 1"). A wrong number is an error with the message of the proc: [`done 9`](run: "error: no note 9").

A proc has its own variables. `global notes` links the name `notes` to the variable at the top level. The result of a proc is the value of `return`, or the result of its last command.

## Control flow

- `if {cond} {...} elseif {cond} {...} else {...}`. The condition is an `expr` expression, in braces.
- `foreach x $list {...}` runs the body for each element. `foreach {k v} $dict {...}` takes two at a time.
- `while {cond} {...}` and `for {init} {cond} {next} {...}` loop. `break` and `continue` work as in C.
- `switch $value {a {...} b {...} default {...}}` matches strings, and `switch -glob` matches patterns.

A body in braces runs when the command runs it. A body in quotes has its `$` and `[ ]` changed one time, when Tcl reads the command. [`set who Ada`](run: "Ada") and [`proc greet {} "return {hi $who}"`](run: "") make a proc with the text `hi Ada` in it. [`set who Bob`](run: "Bob") changes the variable, and [`greet`](run: "hi Ada") still gives the old name.

## upvar and apply

`upvar` links a name in a proc to a variable of its caller. It gives Tcl a way to pass a variable by name. [`proc bump {name} {upvar 1 $name v; incr v}`](run: "") makes the proc, and [`set c 5`](run: "5") and [`bump c`](run: "6") change `c` of the caller. `upvar 1` is the caller, and `upvar #0` is the top level.

`apply` runs a lambda: a list of the arguments and a body. [`apply {{n} {dict get $n text}} [lindex $notes 0]`](run: "buy milk") gets the text of the first note.

## Reading code an agent wrote

- Each body of `proc`, `if`, `foreach`, and `while` is in braces.
- A proc that reads a top-level variable has `global` or `variable` for it. Without it, the read is an error: `can't read "notes": no such variable`.
- An `upvar` has a level: `1` for the caller, `#0` for the top level. Check that the proc is called from the level that the code expects.
- A proc gives an error with `return -code error` or `error`, and the message says what was wrong.

## Mistakes to avoid

These are the traps of lessons 1 to 4, in one list.

1. `expr $a + $b` with no braces: the text of the values runs as code.
2. A list made with quotes: `"home $name"` breaks a value with a space.
3. A body in quotes: its variables change one time, when the proc is made.
4. `==` on strings: `"1.0" == "1"` is true. Use `eq`.
5. A comment only starts at the start of a command. `set x 1 # one` is an error. Write `set x 1 ;# one`.
6. A brace in a comment or in a string in braces counts. Keep the braces even.

## Ask an agent

> Add a proc `find {word}` that gives the numbers of the notes whose text has the word. Use `foreach`, `string match -nocase`, and braces on each body.

## Try this

- Make `show` print `(no notes)` for an empty list.
- Add a proc `undone {i}` that sets `done` to 0.
- Change `bump` to `upvar #0`, and call it from a proc.

If you know Tcl already, [Coming from tclsh](../language.md) lists what ztcl does differently.
