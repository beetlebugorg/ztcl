# Namespaces

A namespace is a group of commands and variables with a name, such as `jot`. It keeps the names of a package apart from the names of other code. An ensemble makes the procs of a namespace into the subcommands of one command. This lesson makes `jot add` and `jot show`.

<!-- checkpoint -->
```tcl
```

## The jot namespace

<!-- define -->
```tcl
namespace eval jot {
    variable notes {}
    proc add {text} {
        variable notes
        lappend notes [dict create text $text done 0]
        return [llength $notes]
    }
    proc show {} {
        variable notes
        set i 0
        foreach n $notes { puts "[incr i]. [dict get $n text]" }
    }
    proc count {} { variable notes; llength $notes }
    namespace export add show count
    namespace ensemble create
}
```

Now `jot` is one command: [`jot add "buy milk"`](run: "1"), [`jot add "fix the bike"`](run: "2"), and [`jot show`](run: ""). The full name of a proc works too: [`jot::count`](run: "2"). A wrong subcommand gives the list of the right ones: [`jot list`](run: "error: unknown or ambiguous subcommand \"list\": must be add, count, or show").

## Names in a namespace

`variable notes` in a proc links the name to the variable of the namespace, as `global` does for the top level. Code outside reads it with the full name: [`set jot::notes`](run: "{text {buy milk} done 0} {text {fix the bike} done 0}"). [`info commands jot::*`](run: "::jot::add ::jot::count ::jot::show") lists the procs.

A name that starts with `::` is a full name from the top. A name with no `::` is looked up in the current namespace, then at the top level for a command. `namespace export` lists the procs of the ensemble, and the other procs stay inside.

## A proc that forgets variable

A proc in a namespace that sets `notes` with no `variable` line makes a local variable. The proc runs with no error, and the notes do not change. [`namespace eval jot { proc clear {} { set notes {} } }`](run: "") makes that bug. [`jot::clear`](run: "") runs, and [`jot::count`](run: "2") shows that the notes are still there.

## Reading code an agent wrote

- Each proc that uses a namespace variable has a `variable` line for it.
- A package keeps its commands in one namespace, and exports only the commands for its users.
- A name with `::` at the start is a full name. Look for a short name that can find a command of the same name at the top level.
- `namespace eval` runs its body in the namespace. In ztcl, as in Tcl 8.6, `set x 1` in that body changes the global `x` when one exists. A namespace variable gets its first value with `variable x 1`.

## Ask an agent

> Put the procs of `jot` in the namespace `jot`, with one `variable` line for each namespace variable in each proc, and an ensemble with `namespace ensemble create`. Export only `add`, `show`, and `count`.

## Try this

- Fix `jot::clear` with a `variable` line, and run it again.
- Add `clear` to the ensemble with `namespace eval jot { namespace export clear }`, and run `jot clear`.
- Run `namespace children ::`.
