# The command reference: lassign. The format is in
# docs/dev/reference-format.md.

command lassign {
    area lists
    since 1.0.0-beta.1
    synopsis {lassign LIST ?VAR ...?}
    summary {Puts the elements of a list in variables, and gives the elements that are left.}
    description {
        Sets each VAR to the element of LIST at its place: the first VAR to the first element, and so on. A VAR with no element left gets an empty string. The elements after the last VAR are the result, as a list.

        With no VAR the result is LIST, as a list.
    }
    returns {The elements of LIST that no variable got, as a list.}
    see {foreach lindex set}
    argument LIST {
        type list
        summary {The list.}
    }
    argument VAR {
        type {variable name}
        optional
        repeats
        summary {A variable for one element.}
    }
    example {lassign {1 2 3} a b} 3
    example {
        lassign {1} a b
        list $a $b
    } {1 {}}
    example {lassign {1 2}} {1 2}
    error "lassign \"a \{b\" x" {unmatched open brace in list} {TCL VALUE LIST BRACE}
    error {lassign} {wrong # args: should be "lassign list ?varName ...?"} {TCL WRONGARGS}
}
