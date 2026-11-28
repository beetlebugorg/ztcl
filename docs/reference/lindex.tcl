# Converted by tools/refdoc.tcl convert from lists.txt.

command lindex {
    area lists
    since TODO
    synopsis {lindex list ?index ...?}
    summary {Gets an element.}
    description {Gets an element. Each further index goes into the element of the earlier one. An index past the end gives an empty string. An index is an integer from 0, `end`, or `end-N`, with `+` and `-` of integers.}
    example {lindex {a b c} end} c
    example {lindex {{a b} {c d}} 1 0} c
}
