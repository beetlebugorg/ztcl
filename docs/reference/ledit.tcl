# Converted by tools/refdoc.tcl convert from lists.txt.

command ledit {
    area lists
    since TODO
    synopsis {ledit listVar first last ?element ...?}
    summary {Replaces the elements from first to last of the list in a variable with the new elements, as `lreplace` does, and gives the new list.}
    description {Replaces the elements from first to last of the list in a variable with the new elements, as `lreplace` does, and gives the new list.}
    tcl {9.1}
    example {set l {a b c d}; ledit l 1 2 X} {a X d}
}
