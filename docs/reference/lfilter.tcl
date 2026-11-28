# The command reference: lfilter. The format is in
# docs/dev/reference-format.md.

command lfilter {
    area lists
    since 1.0.0-beta.1
    tcl 9.1
    synopsis {lfilter VARLIST LIST ?VARLIST LIST ...? SCRIPT}
    summary {Gives the elements of a list for which a script gives true.}
    description {
        Runs SCRIPT once for each element of LIST, with the variables of VARLIST set as `foreach` sets them, and gives a list of the values of the first variable of the first VARLIST for each pass where SCRIPT gives true. The result of SCRIPT must be a boolean.

        With more than one name in VARLIST, each pass gets that many elements. With more than one VARLIST and LIST, the lists go in step, as in `foreach`. `continue` in SCRIPT leaves the element out, and `break` ends the loop with the elements kept so far. An empty LIST gives an empty list.
    }
    returns {The list of the kept values of the first variable.}
    see {lmap foreach lsearch {dict filter}}
    difference {Tcl 9.0.4 has no `lfilter`.}
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
    argument SCRIPT {
        type script
        summary {The test, run for each pass.}
    }
    example {lfilter x {1 2 3 4} {expr {$x % 2 == 0}}} {2 4}
    example {lfilter {a b} {1 2 3 4} {expr {$b > 2}}} 3
    example {lfilter x {1 2} y {3 4} {expr {$y > 3}}} 2
    example {lfilter x {1 2 3} {if {$x == 2} continue; expr 1}} {1 3}
    example {lfilter x {} {expr 1}} {}
    error {lfilter x {1 2} {expr {"x"}}} {expected boolean value but got "x"} NONE
    error {lfilter {} {1} {expr 1}} {lfilter varlist is empty} NONE
    error {lfilter x {1}} {wrong # args: should be "lfilter varList list ?varList list ...? command"} {TCL WRONGARGS}
}
