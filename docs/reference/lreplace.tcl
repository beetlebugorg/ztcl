# The command reference: lreplace. The format is in
# docs/dev/reference-format.md.

command lreplace {
    area lists
    since 1.0.0-beta.1
    synopsis {lreplace LIST FIRST LAST ?ELEMENT ...?}
    summary {Gives a list with a range of elements replaced by new elements.}
    description {
        Gives a new list: LIST with the elements from FIRST to LAST, both included, replaced by the ELEMENT arguments. With no ELEMENT the range goes away. The list of a variable does not change.

        A FIRST below 0 counts as 0, and a LAST past the end counts as the last element. When LAST is before FIRST, no element goes away and the new elements go in before FIRST. A FIRST past the end puts the new elements at the end.
    }
    returns {The new list.}
    see {linsert lrange lset {string replace}}
    argument LIST {
        type list
        summary {The list.}
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
    example {lreplace {a b c d} 1 2 x} {a x d}
    example {lreplace {a b c d} 1 2} {a d}
    example {lreplace {a b c d} 2 1 x} {a b x c d}
    example {lreplace {a b c d} 3 10 x} {a b c x}
    example {lreplace {a b} 5 6 x} {a b x}
    error {lreplace {a b} x 1} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} NONE
    error {lreplace {a b} 0} {wrong # args: should be "lreplace list first last ?element ...?"} {TCL WRONGARGS}
    difference {A bad index has `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL VALUE INDEX` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
}
