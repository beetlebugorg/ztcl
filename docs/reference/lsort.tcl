# Converted by tools/refdoc.tcl convert from lists.txt.

command lsort {
    area lists
    since TODO
    synopsis {lsort ?-option value ...? list}
    summary {A sorted copy of a list.}
    description {A sorted copy of a list. The default order compares the text of the elements. The sort is stable: equal elements keep their order.}
    option -ascii {
        type TODO
        summary {Compares the text (the default).}
        description {Compares the text (the default).}
    }
    option -dictionary {
        type TODO
        summary {Compares the text with no case, and runs of digits as numbers: `a2` before `a10`.}
        description {Compares the text with no case, and runs of digits as numbers: `a2` before `a10`.}
    }
    option -integer {
        type TODO
        summary {Compares integers.}
        description {Compares integers.}
    }
    option -real {
        type TODO
        summary {Compares floats.}
        description {Compares floats.}
    }
    option -command {
        value CMD
        type TODO
        summary {Calls CMD with two elements.}
        description {Calls CMD with two elements. It gives a negative, zero, or positive integer.}
    }
    option -increasing {
        type TODO
        summary {The smallest first (the default).}
        description {The smallest first (the default).}
    }
    option -decreasing {
        type TODO
        summary {The largest first.}
        description {The largest first.}
    }
    option -index {
        value INDEX
        type TODO
        summary {Compares element INDEX of each element.}
        description {Compares element INDEX of each element.}
    }
    option -unique {
        type TODO
        summary {Keeps one of each run of equal elements.}
        description {Keeps one of each run of equal elements.}
    }
    option -nocase {
        type TODO
        summary {Compares letters with no case.}
        description {Compares letters with no case.}
    }
    example {lsort {pear apple fig}} {apple fig pear}
    example {lsort -integer {10 9 100}} {9 10 100}
    example {lsort -dictionary {a10 a2 A1}} {A1 a2 a10}
    example {lsort -index 1 -decreasing {{a 1} {b 3} {c 2}}} {{b 3} {c 2} {a 1}}
}
