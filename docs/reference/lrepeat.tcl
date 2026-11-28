# The command reference: lrepeat. The format is in
# docs/dev/reference-format.md.

command lrepeat {
    area lists
    since 1.0.0-beta.1
    synopsis {lrepeat COUNT ?ELEMENT ...?}
    summary {Makes a list with the same elements repeated a number of times.}
    description {
        Gives a list of the ELEMENT arguments, in order, COUNT times. Each ELEMENT stays one element. A COUNT of 0 gives an empty list, and so does no ELEMENT. A negative COUNT is an error. The result counts toward the memory limit of the interpreter.
    }
    returns {The new list.}
    see {{string repeat} list lseq}
    argument COUNT {
        type {integer, 0 or more}
        summary {The count of copies.}
    }
    argument ELEMENT {
        type {any value}
        optional
        repeats
        summary {An element of each copy.}
    }
    example {lrepeat 3 a b} {a b a b a b}
    example {lrepeat 2 {a b}} {{a b} {a b}}
    example {lrepeat 0 a} {}
    error {lrepeat -1 a} {bad count "-1": must be integer >= 0} NONE
    error {lrepeat x a} {expected integer but got "x"} NONE
    difference {The errors have `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL OPERATION LREPEAT NEGARG` and `TCL VALUE NUMBER` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
}
