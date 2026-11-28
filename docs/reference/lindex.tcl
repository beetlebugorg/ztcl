# The command reference: lindex. The format is in
# docs/dev/reference-format.md.

command lindex {
    area lists
    since 1.0.0-beta.1
    synopsis {lindex LIST ?INDEX ...?}
    summary {Gives the element of a list at an index, or at a path of indexes into nested lists.}
    description {
        Gives the element of LIST at INDEX. Each further INDEX goes one level down into the element of the index before it, so `lindex $l 1 0` is the first element of the second element. One INDEX that is itself a list of indexes, such as `{1 0}`, is the same path.

        An index is an integer from 0, `end`, `end-N`, or `M+N` and `M-N` with integers. An index before the first element or after the last one gives an empty string, at each level. With no INDEX, or with an empty list as INDEX, the result is LIST itself.

        A value on the path that is one word is a list of one element, so `lindex a 0 0` gives `a`.
    }
    returns {The element, or an empty string for an index out of range.}
    see {lrange lset llength {string index}}
    argument LIST {
        type list
        summary {The list.}
    }
    argument INDEX {
        type {index, or a list of indexes}
        optional
        repeats
        summary {The place of the element, one level of the path each.}
    }
    example {lindex {a b c} end} c
    example {lindex {a b c} end-1} b
    example {lindex {{a b} {c d}} 1 0} c
    example {lindex {{a b} {c d}} {1 0}} c
    example {lindex {a b c} 5} {}
    example {lindex {a b c}} {a b c}
    example {lindex {a b} 0 0 0} a
    error {lindex {a b c} x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} NONE
    error "lindex \"a \{b\" 0" {unmatched open brace in list} {TCL VALUE LIST BRACE}
    difference {A bad index has `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL VALUE INDEX` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
}
