# Converted by tools/refdoc.tcl convert from lists.txt.

command lfilter {
    area lists
    since TODO
    synopsis {lfilter varList list ?varList list ...? command}
    summary {Runs the command once for each element, as `foreach` does, and gives the values of the first variable for the passes where the command gives true.}
    description {Runs the command once for each element, as `foreach` does, and gives the values of the first variable for the passes where the command gives true.}
    tcl {9.1}
    example {lfilter x {1 2 3 4} {expr {$x % 2 == 0}}} {2 4}
}
