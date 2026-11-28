# Converted by tools/refdoc.tcl convert from lists.txt.

command lmap {
    area lists
    since TODO
    synopsis {lmap varList list ?varList list ...? command}
    summary {Runs the command for each element, as `foreach` does, and gives a list of the results.}
    description {Runs the command for each element, as `foreach` does, and gives a list of the results. A `continue` leaves out that element.}
    example {lmap x {1 2 3} {expr {$x * $x}}} {1 4 9}
    example {lmap x {1 2 3 4} {if {$x % 2} continue; set x}} {2 4}
}
