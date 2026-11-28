# The command reference: lset. The format is in
# docs/dev/reference-format.md.

command lset {
    area lists
    since 1.0.0-beta.1
    synopsis {lset VAR ?INDEX ...? VALUE}
    summary {Sets one element of the list in a variable, also in nested lists.}
    description {
        Sets the element at INDEX of the list in the variable VAR to VALUE, and gives the new list. Each further INDEX goes one level down into a nested list, and one INDEX that is a list of indexes is the same path, as for `lindex`.

        The index `end+1`, or the count of elements, adds an element at the end. Each other index must be in the list: an index below 0 or more than one past the end is an error. With no INDEX, or with an empty list as INDEX, VALUE replaces the whole value of VAR.

        VAR must have a value. A value on the path that is one word is a list of one element, so `lset l 0 0 0 z` works on the list `{a b}`.
    }
    returns {The new value of VAR.}
    see {lindex lreplace {dict set}}
    argument VAR {
        type {variable name}
        summary {The variable with the list.}
    }
    argument INDEX {
        type {index, or a list of indexes}
        optional
        repeats
        summary {The place of the element, one level of the path each.}
    }
    argument VALUE {
        type {any value}
        summary {The new element.}
    }
    example {
        set l {a b c}
        lset l 1 x
    } {a x c}
    example {
        set l {{a b} {c d}}
        lset l 1 0 x
    } {{a b} {x d}}
    example {
        set l {{a b} {c d}}
        lset l {1 0} y
    } {{a b} {y d}}
    example {
        set l {a b}
        lset l end+1 c
    } {a b c}
    example {
        set l {a b}
        lset l x
    } x
    example {
        set l {a b c}
        lset l 3 0 d
    } {a b c d} -note {The index of the length adds an item at each level of the path: here an empty list at index 3, then `d` in it.}
    error {
        set l {a b}
        lset l 5 c
    } {list index out of range} {TCL OPERATION LSET BADINDEX} -tcl 8.6
    error {
        set l {a b}
        lset l 5 c
    } {index "5" out of range} {TCL VALUE INDEX OUTOFRANGE} -tcl 9.1
    error {
        unset -nocomplain nv
        lset nv 0 x
    } {can't read "nv": no such variable} NONE
    error {lset} {wrong # args: should be "lset listVar ?index? ?index ...? value"} {TCL WRONGARGS}
    release {In Tcl 9.1 the message of an index out of range names the index, as in `index "5" out of range`, with the code `TCL VALUE INDEX OUTOFRANGE`. Tcl 8.6 gives `list index out of range` with `TCL OPERATION LSET BADINDEX`.}
}
