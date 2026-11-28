# Converted by tools/refdoc.tcl convert from lists.txt.

command lremove {
    area lists
    since TODO
    synopsis {lremove list ?index ...?}
    summary {The list without the elements at the indexes.}
    description {The list without the elements at the indexes. An index past the end has no effect.}
    tcl {9.1}
    example {lremove {a b c d} 1 end} {a c}
}
