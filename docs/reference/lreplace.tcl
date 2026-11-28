# Converted by tools/refdoc.tcl convert from lists.txt.

command lreplace {
    area lists
    since TODO
    synopsis {lreplace list first last ?element ...?}
    summary {A new list with the elements from first to last replaced by the new elements.}
    description {A new list with the elements from first to last replaced by the new elements. With no new elements, it removes them.}
    example {lreplace {a b c d} 1 2 x} {a x d}
}
