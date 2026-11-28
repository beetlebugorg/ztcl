# The command reference: lrange. The format is in
# docs/dev/reference-format.md.

command lrange {
    area lists
    since 1.0.0-beta.1
    synopsis {lrange LIST FIRST LAST}
    summary {Gives the elements of a list from one index to another, as a list.}
    description {
        Gives the elements of LIST from FIRST to LAST, both included, as a new list. A FIRST below 0 counts as 0, and a LAST past the end counts as the last element. When FIRST is after LAST, after that clamp, the result is an empty list.

        The elements keep their form: an element in braces stays in braces.
    }
    returns {A list, empty when the range has no element.}
    see {lindex lreplace {string range}}
    argument LIST {
        type list
        summary {The list.}
    }
    argument FIRST {
        type index
        summary {The index of the first element of the result.}
    }
    argument LAST {
        type index
        summary {The index of the last element of the result.}
    }
    example {lrange {a b c d} 1 end-1} {b c}
    example {lrange {a b c d} -3 1} {a b}
    example {lrange {a b c d} 2 99} {c d}
    example {lrange {a b c d} 2 1} {}
    example {lrange {a {b c} d} 1 1} {{b c}}
    error {lrange {a b} x 1} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} NONE
    error {lrange {a b} 0} {wrong # args: should be "lrange list first last"} {TCL WRONGARGS}
    difference {A bad index has `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL VALUE INDEX` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
}
