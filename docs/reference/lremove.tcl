# The command reference: lremove. The format is in
# docs/dev/reference-format.md.

command lremove {
    area lists
    since 1.0.0-beta.1
    tcl 9.1
    synopsis {lremove LIST ?INDEX ...?}
    summary {Gives a list with the elements at some indexes removed.}
    description {
        Gives a new list: LIST with no element at any of the INDEX arguments. The indexes all refer to LIST as it is, so their order does not matter, and an index that comes twice removes one element. An index out of range has no effect and is no error. With no INDEX the result is LIST.
    }
    returns {The new list.}
    see {lreplace lpop lsearch}
    difference {A bad index has `-errorcode NONE`, where Tcl 9.0.4 gives `TCL VALUE INDEX` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
    argument LIST {
        type list
        summary {The list.}
    }
    argument INDEX {
        type index
        optional
        repeats
        summary {The index of an element to remove.}
    }
    example {lremove {a b c d} 1 end} {a c}
    example {lremove {a b c d} end-1 0} {b d}
    example {lremove {a b c d} 1 1} {a c d}
    example {lremove {a b c d} 5} {a b c d}
    example {lremove {a b c d}} {a b c d}
    error {lremove {a b} x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} NONE
    error {lremove} {wrong # args: should be "lremove list ?index ...?"} {TCL WRONGARGS}
}
