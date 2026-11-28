# Converted by tools/refdoc.tcl convert from lists.txt.

command lassign {
    area lists
    since TODO
    synopsis {lassign list ?varName ...?}
    summary {Puts the elements of a list in the variables, in order, and gives the elements that are left.}
    description {Puts the elements of a list in the variables, in order, and gives the elements that are left. A variable with no element gets an empty string.}
    example {lassign {1 2 3} a b} 3
}
