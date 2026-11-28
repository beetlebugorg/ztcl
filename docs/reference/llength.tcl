# Converted by tools/refdoc.tcl convert from lists.txt.

command llength {
    area lists
    since TODO
    synopsis {llength list}
    summary {The count of elements of a list.}
    description {The count of elements of a list.}
    example {llength {a {b c} d}} 3
    error "llength \"a \{b\"" {unmatched open brace in list} {TCL VALUE LIST BRACE}
}
