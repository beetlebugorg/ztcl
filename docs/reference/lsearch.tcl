# The command reference: lsearch. The format is in
# docs/dev/reference-format.md.

command lsearch {
    area lists
    since 1.0.0-beta.1
    synopsis {lsearch ?OPTION ...? LIST PATTERN}
    summary {Finds the elements of a list that match a pattern.}
    description {
        Searches LIST for an element that matches PATTERN, and gives the index of the first one, or -1 when no element matches. The options choose how an element matches, what the search gives, and where it starts.

        The way of matching is one of `-glob` (the default), `-exact`, `-regexp`, and `-sorted`. With `-exact` and `-sorted`, the type options `-ascii` (the default), `-dictionary`, `-integer`, and `-real` say how two values compare. `-nocase` compares letters with no regard to case.

        `-all` gives each match in place of the first, `-inline` gives the elements in place of their indexes, and `-not` finds the elements that do not match. `-index` compares an element of each element, and `-stride` reads the list as groups. A unique prefix of an option is the option, and the options come before LIST.

        An empty LIST gives -1, or an empty list with `-all` or `-inline`.
    }
    returns {The index of the first match or -1, the indexes of each match with `-all`, or the elements with `-inline`.}
    see {lsort lindex {string match} regexp lmap}
    argument LIST {
        type list
        summary {The list to search.}
    }
    argument PATTERN {
        type {glob pattern, value, or regular expression}
        summary {What to find, read by the way of matching.}
    }
    example {lsearch {a b c} c} 2
    example {lsearch {a b c} z} -1
    example {lsearch {apple box ant} a*} 0
    example {lsearch -all -inline {apple box ant} a*} {apple ant}
    example {lsearch -index 0 {{x 1} {y 2}} y} 1
    example {lsearch -exact -all -inline -not {a b c b} b} {a c}
    error {lsearch {a}} {wrong # args: should be "lsearch ?-option value ...? list pattern"} {TCL WRONGARGS}
    error {lsearch -bogus {a} a} {bad option "-bogus": must be -all, -ascii, -bisect, -decreasing, -dictionary, -exact, -glob, -increasing, -index, -inline, -integer, -nocase, -not, -real, -regexp, -sorted, -start, -stride, or -subindices} NONE -tcl 9.1
    error {lsearch -bogus {a} a} {bad option "-bogus": must be -all, -ascii, -bisect, -decreasing, -dictionary, -exact, -glob, -increasing, -index, -inline, -integer, -nocase, -not, -real, -regexp, -sorted, -start, or -subindices} NONE -tcl 8.6
    error "lsearch \"a \{b\" a" {unmatched open brace in list} {TCL VALUE LIST BRACE}
    release {Tcl 9.1 has the option `-stride`.}
    difference {Most errors have `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give a code such as `TCL LOOKUP INDEX option` or `TCL VALUE INDEX` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
    release {In Tcl 9.1 the message of a bad regular expression starts with `cannot compile`, and in Tcl 8.6 with `couldn't compile`.}
    release {With `-subindices -inline` and no `-all`, Tcl 8.6 gives the whole element and Tcl 9.1 gives the subelement. With `-all` both give the subelements.}

    option -glob {
        type flag
        summary {Matches PATTERN as a glob pattern; the default.}
        description {Matches each element against PATTERN with the rules of `string match`: `*`, `?`, and `[chars]`. It is the way of matching with no option of its kind.}
        example {lsearch -glob {abc} a?c} 0
        example {lsearch -glob -nocase {ABC} a*} 0
        noerrors {Each text is a valid glob pattern.}
    }
    option -exact {
        type flag
        summary {Matches an element that equals PATTERN.}
        description {Matches an element that is the same value as PATTERN, with the comparison of the type option: text for `-ascii`, numbers for `-integer` and `-real`. A glob character such as `*` is a plain character.}
        example {lsearch -exact {a* b} a*} 0
        example {lsearch -exact -integer {01 2} 1} 0
        noerrors {Each value is a valid PATTERN for an exact match.}
    }
    option -regexp {
        type flag
        summary {Matches PATTERN as a regular expression.}
        description {Matches an element that has a match of the regular expression PATTERN anywhere in it, with the rules of `regexp`. Anchor it with `^` and `$` for a match of the whole element.}
        example {lsearch -regexp {abc xyz} {^x}} 1
        example {lsearch -regexp -nocase {ABC} {^a}} 0
        error {lsearch -regexp {abc} (} {couldn't compile regular expression pattern: parentheses () not balanced} {REGEXP REG_EPAREN {parentheses () not balanced}} -tcl 8.6
        error {lsearch -regexp {abc} (} {cannot compile regular expression pattern: parentheses () not balanced} {REGEXP REG_EPAREN {parentheses () not balanced}} -tcl 9.1
    }
    option -sorted {
        type flag
        summary {Searches a sorted list with a binary search.}
        description {
            LIST must be sorted in the order of the type option and of `-increasing` or `-decreasing`, and the search is a binary search for an element equal to PATTERN. On a list that is not sorted, the result has no meaning. With `-all` it gives each equal element. With `-start` it searches from that index.

            `-sorted` is an exact match: PATTERN has no glob characters.
        }
        example {lsearch -sorted {a b c d} c} 2
        example {lsearch -sorted -integer {1 5 9 12} 9} 2
        example {lsearch -all -sorted {a a b} a} {0 1}
        error {lsearch -sorted -bisect -all {a b} a} {-bisect is not compatible with -all or -not} NONE
    }
    option -bisect {
        type flag
        summary {Gives the index of the last element at or before PATTERN in a sorted list.}
        description {With `-sorted`, the search gives the index of the last element that is less than or equal to PATTERN in the sort order, or -1 when each element is greater. It does not need an equal element. It cannot go with `-all` or `-not`.}
        example {lsearch -sorted -bisect {a b d} c} 1
        example {lsearch -sorted -bisect -integer {1 5 9} 6} 1
        example {lsearch -sorted -bisect {b c} a} -1
        error {lsearch -sorted -bisect -all {a b} a} {-bisect is not compatible with -all or -not} NONE
    }
    option -all {
        type flag
        summary {Gives each match in place of the first one.}
        description {Gives a list of the index of each matching element, in order, or an empty list when no element matches. With `-inline` it gives the elements.}
        example {lsearch -all {a b a} a} {0 2}
        example {lsearch -all {a b} z} {}
        error {lsearch -sorted -bisect -all {a b} a} {-bisect is not compatible with -all or -not} NONE
    }
    option -inline {
        type flag
        summary {Gives the matching elements in place of their indexes.}
        description {Gives the first matching element, or an empty string when no element matches. With `-all` it gives a list of each matching element.}
        example {lsearch -inline {apple box} b*} box
        example {lsearch -inline {apple box} z*} {}
        noerrors {A flag has no value to check.}
    }
    option -not {
        type flag
        summary {Finds the elements that do not match.}
        description {Turns the test around: the search finds the elements that do not match PATTERN. It goes with each way of matching except `-bisect`.}
        example {lsearch -not {a b c} a} 1
        example {lsearch -not -all {a b c} a} {1 2}
        example {lsearch -inline -not {a b} a} b
        error {lsearch -sorted -bisect -not {a b} a} {-bisect is not compatible with -all or -not} NONE
    }
    option -start {
        value INDEX
        type index
        default 0
        summary {Starts the search at an index.}
        description {The search starts at INDEX and goes to the end, and the indexes of the result are indexes of the whole list. `end` and `end-N` count from the last element.}
        example {lsearch -start 2 {a b a b} a} 2
        example {lsearch -all -start 1 {a b a} a} 2
        example {lsearch -start end {a b a} a} 2
        error {lsearch -start x {a} a} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} NONE
    }
    option -ascii {
        type flag
        summary {Compares the elements as text; the default type.}
        description {With `-exact` and `-sorted`, two values are equal when their text is the same, and `-sorted` uses the order of the characters.}
        example {lsearch -exact -ascii {10 9} 9} 1
        noerrors {A flag has no value to check.}
    }
    option -dictionary {
        type flag
        summary {Compares the elements in dictionary order.}
        description {With `-sorted`, the order is the order of `lsort -dictionary`: runs of digits compare as numbers. An exact match is still a match of the same text, so `-dictionary` does not fold the case of letters.}
        example {lsearch -sorted -dictionary {a2 a10} a10} 1
        example {lsearch -exact -dictionary {A b} a} -1
        noerrors {A flag has no value to check.}
    }
    option -integer {
        type flag
        summary {Compares the elements as integers.}
        description {With `-exact` and `-sorted`, two values are equal when they are the same integer, so `01` equals `1`. An element that is not an integer does not match.}
        example {lsearch -exact -integer {1 01 2} 1} 0
        example {lsearch -integer {a 1} x} -1
        noerrors {An element or a PATTERN that is not an integer does not match, and the search goes on.}
    }
    option -real {
        type flag
        summary {Compares the elements as floating-point numbers.}
        description {With `-exact` and `-sorted`, two values are equal when they are the same number, so `1.0` equals `1`.}
        example {lsearch -exact -real {1.0 2} 1} 0
        example {lsearch -sorted -real {1.5 2.5} 2.5} 1
        noerrors {An element that is not a number does not match.}
    }
    option -nocase {
        type flag
        summary {Matches letters with no regard to case.}
        description {Compares the letters of PATTERN and of each element as lowercase, for each way of matching.}
        example {lsearch -nocase {A b} a} 0
        example {lsearch -sorted -nocase {A b C} c} 2
        noerrors {A flag has no value to check.}
    }
    option -increasing {
        type flag
        summary {Says that a sorted list is in increasing order; the default.}
        description {With `-sorted`, the list goes from the smallest element to the largest. With no `-sorted` the option has no effect.}
        example {lsearch -sorted -increasing {a b c} b} 1
        example {lsearch -increasing {b a} a} 1
        noerrors {A flag has no value to check.}
    }
    option -decreasing {
        type flag
        summary {Says that a sorted list is in decreasing order.}
        description {With `-sorted`, the list goes from the largest element to the smallest. With no `-sorted` the option has no effect.}
        example {lsearch -sorted -decreasing -integer {9 5 1} 5} 1
        example {lsearch -decreasing {b a} a} 1
        noerrors {A flag has no value to check.}
    }
    option -index {
        value INDEX
        type {index, or a list of indexes}
        summary {Compares an element of each element in place of the whole element.}
        description {Each element of LIST is a list, and the search compares its element at INDEX, or at the path of a list of indexes. Each element must have that index. The result is the index of the element of LIST, or the whole element with `-inline`.}
        example {lsearch -index 1 {{x 1} {y 2}} 2} 1
        example {lsearch -index 1 -inline {{x 1} {y 2}} 2} {y 2}
        example {lsearch -index 0 -sorted {{a 1} {b 2}} b} 1
        error {lsearch -index 5 {{x 1}} 2} {element 5 missing from sublist "x 1"} NONE
    }
    option -subindices {
        type flag
        summary {With -index, gives the path of the match or the subelement.}
        description {With `-index`, the result of a match is the index of the element followed by the indexes of `-index`: a path for `lindex`. With `-inline` it is the subelement at that path in place of the whole element, except in Tcl 8.6 with no `-all`: there it is the whole element.}
        example {lsearch -subindices -index 1 {{x 1} {y 2}} 2} {1 1}
        example {lsearch -subindices -index 1 -inline {{x 1} {y 2}} 2} 2 -tcl 9.1
        example {lsearch -subindices -index 1 -inline {{x 1} {y 2}} 2} {y 2} -tcl 8.6
        example {lsearch -subindices -index 1 -all -inline {{x 1} {y 2}} *} {1 2}
        error {lsearch -subindices -index 5 {{x 1}} 2} {element 5 missing from sublist "x 1"} NONE
    }
    option -stride {
        value N
        type {integer, 1 or more}
        default 1
        tcl 9.1
        summary {Reads the list as groups of N elements.}
        description {The list is groups of N elements, and its length must be a multiple of N. The search compares the first element of each group, or the element of `-index` in the group, and gives the index of the first element of the group. With `-inline` it gives the whole group.}
        example {lsearch -stride 2 {a 1 b 2} b} 2
        example {lsearch -stride 2 -index 1 {a 1 b 2} 2} 2
        example {lsearch -stride 2 -inline {a 1 b 2} b} {b 2}
        example {lsearch -stride 2 -all {a 1 a 2} a} {0 2}
        error {lsearch -stride 3 {a b} a} {list size must be a multiple of the stride length} NONE
        error {lsearch -stride 0 {a} a} {stride length must be at least 1} NONE
    }
}
