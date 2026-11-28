# The command reference: ledit. The format is in
# docs/dev/reference-format.md.

command ledit {
    area lists
    since 1.0.0-beta.1
    tcl 9.1
    synopsis {ledit VAR FIRST LAST ?ELEMENT ...?}
    summary {Replaces a range of elements of the list in a variable.}
    description {
        Replaces the elements from FIRST to LAST of the list in the variable VAR with the ELEMENT arguments, as `lreplace` does, sets VAR to the new list, and gives it. With no ELEMENT the range goes away. When LAST is before FIRST, the new elements go in before FIRST, and `end+1` as FIRST adds them at the end.

        VAR must have a value.
    }
    returns {The new value of VAR.}
    see {lreplace lset linsert}
    difference {A variable with no value has `-errorcode NONE`, where Tcl 9.0.4 gives `TCL LOOKUP VARNAME` ([issue 730](https://github.com/beetlebugorg/ztcl/issues/730)).}
    argument VAR {
        type {variable name}
        summary {The variable with the list.}
    }
    argument FIRST {
        type index
        summary {The index of the first element to replace.}
    }
    argument LAST {
        type index
        summary {The index of the last element to replace.}
    }
    argument ELEMENT {
        type {any value}
        optional
        repeats
        summary {A new element.}
    }
    example {
        set l {a b c d}
        ledit l 1 2 X
    } {a X d}
    example {
        set l {a b c d}
        ledit l 1 2
    } {a d}
    example {
        set l {a b c d}
        ledit l 2 1 X
    } {a b X c d}
    example {
        set l {a b}
        ledit l end+1 end+1 c
    } {a b c}
    error {
        set l {a b}
        ledit l x 1
    } {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
    error {
        unset -nocomplain nv
        ledit nv 0 0 a
    } {can't read "nv": no such variable} NONE
    error {ledit l 0} {wrong # args: should be "ledit listVar first last ?element ...?"} {TCL WRONGARGS}
}
