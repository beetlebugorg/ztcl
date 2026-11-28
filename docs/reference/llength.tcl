# The command reference: llength. The format is in
# docs/dev/reference-format.md.

command llength {
    area lists
    since 1.0.0-beta.1
    synopsis {llength LIST}
    summary {Gives the count of elements of a list.}
    description {
        Gives the count of elements of LIST. White space around and between the elements does not count, and an empty string is an empty list with 0 elements. An element in braces counts as one element, whatever it has inside.

        LIST must be a valid list: an unbalanced brace or quote is an error.
    }
    returns {A non-negative integer.}
    see {lindex {string length} {dict size}}
    argument LIST {
        type list
        summary {The list to count.}
    }
    example {llength {a {b c} d}} 3
    example {llength {}} 0
    example {llength "  a   b  "} 2
    error "llength \"a \{b\"" {unmatched open brace in list} {TCL VALUE LIST BRACE}
    error {llength a b} {wrong # args: should be "llength list"} {TCL WRONGARGS}
}
