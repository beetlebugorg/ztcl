# The command reference: lreverse. The format is in
# docs/dev/reference-format.md.

command lreverse {
    area lists
    since 1.0.0-beta.1
    synopsis {lreverse LIST}
    summary {Gives the elements of a list in the reverse order.}
    description {
        Gives a new list with the elements of LIST from the last to the first. Each element stays whole: a nested list is one element and keeps its own order. An empty list gives an empty list.
    }
    returns {The new list.}
    see {lsort {string reverse}}
    argument LIST {
        type list
        summary {The list.}
    }
    example {lreverse {a b c}} {c b a}
    example {lreverse {a {b c}}} {{b c} a}
    example {lreverse {}} {}
    error "lreverse \"a \{b\"" {unmatched open brace in list} {TCL VALUE LIST BRACE}
    error {lreverse} {wrong # args: should be "lreverse list"} {TCL WRONGARGS}
}
