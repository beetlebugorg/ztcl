# The command reference: lappend. The format is in
# docs/dev/reference-format.md.

command lappend {
    area lists
    since 1.0.0-beta.1
    synopsis {lappend VAR ?VALUE ...?}
    summary {Adds values as elements to the end of the list in a variable.}
    description {
        Adds each VALUE as one element to the end of the list in the variable VAR, and gives the new list. A value with spaces stays one element. A VAR with no value starts as an empty list, so `lappend` also makes a variable. With no VALUE the list stays as it is, and a missing VAR becomes an empty list.

        The value of VAR must be a valid list.
    }
    returns {The new value of VAR.}
    see {list linsert append {dict lappend}}
    argument VAR {
        type {variable name}
        summary {The variable with the list.}
    }
    argument VALUE {
        type {any value}
        optional
        repeats
        summary {An element to add.}
    }
    example {
        set l {a}
        lappend l "b c"
    } {a {b c}}
    example {
        unset -nocomplain nl
        lappend nl x y
    } {x y}
    example {
        set l {a}
        lappend l
    } a
    error {
        set bad "a \{b"
        lappend bad c
    } {unmatched open brace in list} {TCL VALUE LIST BRACE}
    error {lappend} {wrong # args: should be "lappend varName ?value ...?"} {TCL WRONGARGS}
}
