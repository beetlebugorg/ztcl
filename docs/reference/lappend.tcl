# Converted by tools/refdoc.tcl convert from lists.txt.

command lappend {
    area lists
    since TODO
    synopsis {lappend varName ?value ...?}
    summary {Adds each value as one element to the list in the variable, and gives the new list.}
    description {Adds each value as one element to the list in the variable, and gives the new list. It makes the variable when it has no value.}
    example {set l {a}; lappend l "b c"} {a {b c}}
}
