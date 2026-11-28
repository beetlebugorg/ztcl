# Converted by tools/refdoc.tcl convert from lists.txt.

command lsearch {
    area lists
    since TODO
    synopsis {lsearch ?-option value ...? list pattern}
    summary {Finds an element.}
    description {Finds an element. It gives the index of the first match, or -1. The default match is a glob pattern.}
    option -exact {
        type TODO
        summary {The element equals the pattern.}
        description {The element equals the pattern.}
    }
    option -glob {
        type TODO
        summary {A glob pattern (the default).}
        description {A glob pattern (the default).}
    }
    option -regexp {
        type TODO
        summary {A regular expression.}
        description {A regular expression.}
    }
    option -all {
        type TODO
        summary {Gives each index that matches.}
        description {Gives each index that matches.}
    }
    option -inline {
        type TODO
        summary {Gives the elements in place of the indexes.}
        description {Gives the elements in place of the indexes.}
    }
    option -not {
        type TODO
        summary {Finds the elements that do not match.}
        description {Finds the elements that do not match.}
    }
    option -nocase {
        type TODO
        summary {Matches letters with no case.}
        description {Matches letters with no case.}
    }
    option -index {
        value INDEX
        type TODO
        summary {Compares element INDEX of each element.}
        description {Compares element INDEX of each element.}
    }
    option -sorted {
        type TODO
        summary {The list is sorted, and the search is a binary search.}
        description {The list is sorted, and the search is a binary search.}
    }
    option -start {
        value INDEX
        type TODO
        summary {Starts at INDEX.}
        description {Starts at INDEX.}
    }
    option -stride {
        value N
        type TODO
        summary {Tcl 9.1 only: the list is groups of N elements.}
        description {Tcl 9.1 only: the list is groups of N elements. The search compares the first element of each group, or the element of -index in the group, and gives the index of the group. With -inline it gives the group.}
    }
    example {lsearch {a b c} c} 2
    example {lsearch -all -inline {apple box ant} a*} {apple ant}
    example {lsearch -index 0 {{x 1} {y 2}} y} 1
}
