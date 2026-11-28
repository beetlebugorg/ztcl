# The command reference: lpop. The format is in
# docs/dev/reference-format.md.

command lpop {
    area lists
    since 1.0.0-beta.1
    tcl 9.1
    synopsis {lpop VAR ?INDEX ...?}
    summary {Removes an element from the list in a variable and gives it.}
    description {
        Removes the element at INDEX from the list in the variable VAR, and gives that element. The default INDEX is `end`, so `lpop` with no INDEX removes the last element. Each further INDEX goes one level down into a nested list, and one INDEX that is a list of indexes is the same path.

        The index must be an element of the list: an empty list, or an index out of range, is an error, and VAR keeps its value. VAR must have a value.
    }
    returns {The element that was taken out.}
    see {lindex lremove lset lappend}
    difference {A variable with no value has `-errorcode NONE`, where Tcl 9.0.4 gives `TCL LOOKUP VARNAME` ([issue 730](https://github.com/beetlebugorg/ztcl/issues/730)).}
    argument VAR {
        type {variable name}
        summary {The variable with the list.}
    }
    argument INDEX {
        type {index, or a list of indexes}
        optional
        repeats
        default end
        summary {The place of the element, one level of the path each.}
    }
    example {
        set l {a b c}
        list [lpop l] $l
    } {c {a b}}
    example {
        set l {a b c}
        list [lpop l 0] $l
    } {a {b c}}
    example {
        set l {a b c}
        list [lpop l end-1] $l
    } {b {a c}}
    example {
        set l {{a b} c}
        list [lpop l 0 0] $l
    } {a {b c}}
    error {
        set l {}
        lpop l
    } {index "end" out of range} {TCL VALUE INDEX OUTOFRANGE}
    error {
        set l {a b}
        lpop l 5
    } {index "5" out of range} {TCL VALUE INDEX OUTOFRANGE}
    error {
        unset -nocomplain nv
        lpop nv
    } {can't read "nv": no such variable} NONE
    error {lpop} {wrong # args: should be "lpop listvar ?index?"} {TCL WRONGARGS}
}
