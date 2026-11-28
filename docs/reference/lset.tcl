# Converted by tools/refdoc.tcl convert from lists.txt.

command lset {
    area lists
    since TODO
    synopsis {lset listVar ?index? ?index ...? value}
    summary {Sets one element of the list in a variable, and gives the new list.}
    description {Sets one element of the list in a variable, and gives the new list. More indexes go into nested lists. The index `end+1` adds an element.}
    example {set l {a b c}; lset l 1 x} {a x c}
}
