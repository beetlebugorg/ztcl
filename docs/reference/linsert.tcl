# The command reference: linsert. The format is in
# docs/dev/reference-format.md.

command linsert {
    area lists
    since 1.0.0-beta.1
    synopsis {linsert LIST INDEX ?ELEMENT ...?}
    summary {Gives a list with elements put in before an index.}
    description {
        Gives a new list: LIST with each ELEMENT put in before the element at INDEX, in order. The list of a variable does not change.

        `end` and each index past the end put the elements after the last element. An index at or below 0 puts them at the start. With no ELEMENT the result is LIST.
    }
    returns {The new list.}
    see {lappend lreplace {string insert}}
    argument LIST {
        type list
        summary {The list.}
    }
    argument INDEX {
        type index
        summary {The place of the new elements.}
    }
    argument ELEMENT {
        type {any value}
        optional
        repeats
        summary {An element to put in.}
    }
    example {linsert {a d} 1 b c} {a b c d}
    example {linsert {a b} end x} {a b x}
    example {linsert {a b} end+5 x} {a b x}
    example {linsert {a b} -3 x} {x a b}
    example {linsert {a b} 1} {a b}
    error {linsert {a b} x y} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} NONE
    error {linsert {a b}} {wrong # args: should be "linsert list index ?element ...?"} {TCL WRONGARGS}
    difference {A bad index has `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL VALUE INDEX` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
}
