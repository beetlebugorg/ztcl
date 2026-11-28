# The command reference: foreach. The format is in
# docs/dev/reference-format.md.

command foreach {
    area lists
    since 1.0.0-beta.1
    synopsis {foreach VARLIST LIST ?VARLIST LIST ...? BODY}
    summary {Runs a script for each element of one or more lists.}
    description {
        Runs BODY once for each element of LIST, with the variable of VARLIST set to the element. With more than one name in VARLIST, each pass sets that many variables from the next elements, and a variable with no element left in the last pass gets an empty string.

        With more than one VARLIST and LIST, the lists go in step: each pass sets the variables from the next elements of each list, and the loop runs as many passes as the longest list needs. A variable of a list with no element left gets an empty string.

        `continue` in BODY goes on with the next pass, and `break` ends the loop. An error in BODY ends the loop with that error. The variables keep the values of the last pass after the loop, and an empty LIST leaves them as they were. The result is an empty string.
    }
    returns {An empty string.}
    see {lmap lfilter lassign {dict for} for while}
    argument VARLIST {
        type {list of variable names}
        repeats
        summary {The variables of one list, at least one name.}
    }
    argument LIST {
        type list
        repeats
        summary {A list to go through.}
    }
    argument BODY {
        type script
        summary {The script to run for each pass.}
    }
    example {
        set out {}
        foreach {k v} {a 1 b 2} {append out $k=$v,}
        set out
    } a=1,b=2,
    example {
        set n 0
        foreach x {1 2 3} {incr n $x}
        set n
    } 6
    example {
        set r {}
        foreach x {a b} y {1 2 3} {lappend r $x$y}
        set r
    } {a1 b2 3}
    example {
        set r {}
        foreach {a b} {1 2 3} {lappend r [list $a $b]}
        set r
    } {{1 2} {3 {}}}
    example {
        set r {}
        foreach x {1 2 3 4} {if {$x == 2} continue; if {$x == 4} break; lappend r $x}
        set r
    } {1 3}
    example {
        set x 9
        foreach x {1 2} {}
        set x
    } 2
    example {foreach x {1 2} {set x}} {} -note {The result is empty, whatever BODY gives.}
    error {foreach {} {1} {}} {foreach varlist is empty} NONE
    error {foreach x {1 2} {error boom}} boom NONE
    error {foreach x {1}} {wrong # args: should be "foreach varList list ?varList list ...? command"} {TCL WRONGARGS}
    difference {An empty VARLIST has `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL OPERATION FOREACH NEEDVARS` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
}
