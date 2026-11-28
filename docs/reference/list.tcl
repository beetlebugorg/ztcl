# The command reference: list. The format is in
# docs/dev/reference-format.md.

command list {
    area lists
    since 1.0.0-beta.1
    synopsis {list ?ARG ...?}
    summary {Makes a list with each argument as one element.}
    description {
        Makes a list with each argument as one element, in order. It adds the braces and backslashes that an element needs, so that each value stays one element when the list is read again: a value with a space gets braces, and a value with an unbalanced brace gets backslashes.

        With no argument it gives an empty list. An empty argument is an element too, and it shows as `{}`.
    }
    returns {The new list.}
    see {lappend linsert concat split join}
    argument ARG {
        type {any value}
        optional
        repeats
        summary {One element of the list.}
    }
    example {list a "b c" {}} {a {b c} {}}
    example {list} {}
    example {list "a{b" "c}" {$x} "#x"} "a\\\{b c\\\} {\$x} #x" -note {Backslashes keep an unbalanced brace in its element.}
    example {llength [list "a b" c]} 2
    noerrors {Each count of arguments is valid, also none, and each value can be an element.}
}
