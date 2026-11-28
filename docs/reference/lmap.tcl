# The command reference: lmap. The format is in
# docs/dev/reference-format.md.

command lmap {
    area lists
    since 1.0.0-beta.1
    synopsis {lmap VARLIST LIST ?VARLIST LIST ...? BODY}
    summary {Runs a script for each element of one or more lists, and gives a list of the results.}
    description {
        Runs BODY for each pass as `foreach` does, and gives a list with the result of BODY of each pass, in order. The variables, the passes, and the lists in step follow the rules of `foreach`.

        `continue` in BODY leaves the pass out of the result, and `break` ends the loop with the results so far. An error in BODY ends the loop with that error. An empty BODY gives an empty element for each pass, and an empty LIST gives an empty list.
    }
    returns {The list of the results of BODY.}
    see {foreach lfilter {dict map} {string map}}
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
        summary {The script that gives each element of the result.}
    }
    example {lmap x {1 2 3} {expr {$x * $x}}} {1 4 9}
    example {lmap x {1 2 3 4} {if {$x % 2} continue; set x}} {2 4}
    example {lmap x {1 2 3 4} {if {$x == 3} break; set x}} {1 2}
    example {lmap {a b} {1 2 3 4 5} {list $a $b}} {{1 2} {3 4} {5 {}}}
    example {lmap x {1 2} y {a b c} {list $x $y}} {{1 a} {2 b} {{} c}}
    example {lmap x {1 2} {}} {{} {}}
    error {lmap {} {1} {set x}} {lmap varlist is empty} NONE
    error {lmap x {1 2} {error oops}} oops NONE
    error {lmap x {1}} {wrong # args: should be "lmap varList list ?varList list ...? command"} {TCL WRONGARGS}
    difference {An empty VARLIST has `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL OPERATION LMAP NEEDVARS` ([issue 730](https://github.com/beetlebugorg/ztcl/issues/730)).}
}
