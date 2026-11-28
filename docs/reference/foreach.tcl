# Converted by tools/refdoc.tcl convert from lists.txt.

command foreach {
    area lists
    since TODO
    synopsis {foreach varList list ?varList list ...? command}
    summary {Runs the command for each element of the list.}
    description {Runs the command for each element of the list. With a varList of more than one name, it gets that many elements each time. With more than one list, it goes through each list in step.}
    example {set out {}; foreach {k v} {a 1 b 2} {append out $k=$v,}; set out} a=1,b=2,
}
