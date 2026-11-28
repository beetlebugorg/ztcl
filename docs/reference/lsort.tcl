# The command reference: lsort. The format is in
# docs/dev/reference-format.md.

command lsort {
    area lists
    since 1.0.0-beta.1
    synopsis {lsort ?OPTION ...? LIST}
    summary {Gives a sorted copy of a list.}
    description {
        Gives the elements of LIST in sorted order, as a new list. The type options say how two elements compare: `-ascii` (the default) compares their text by the code points of the characters, `-dictionary` compares runs of digits as numbers, `-integer` and `-real` compare numbers, and `-command` calls a script. `-increasing` (the default) and `-decreasing` give the direction.

        The sort is stable: elements that compare equal keep their order. `-unique` keeps one element of each group of equal elements, `-indices` gives indexes in place of elements, `-index` compares an element of each element, and `-stride` sorts groups of elements.

        A unique prefix of an option is the option, and the options come before LIST. An empty LIST gives an empty list.
    }
    returns {The sorted list, or the list of the indexes of the elements in sorted order with `-indices`.}
    see {lsearch lreverse {string compare} {dict keys}}
    argument LIST {
        type list
        summary {The list to sort.}
    }
    example {lsort {pear apple fig}} {apple fig pear}
    example {lsort {10 9 100}} {10 100 9} -note {The text of the elements, by default.}
    example {lsort -integer {10 9 100}} {9 10 100}
    example {lsort -dictionary {a10 a2 A1}} {A1 a2 a10}
    example {lsort -index 1 -decreasing {{a 1} {b 3} {c 2}}} {{b 3} {c 2} {a 1}}
    error {lsort} {wrong # args: should be "lsort ?-option value ...? list"} {TCL WRONGARGS}
    error {lsort -bogus {a}} {bad option "-bogus": must be -ascii, -command, -decreasing, -dictionary, -increasing, -index, -indices, -integer, -nocase, -real, -stride, or -unique} NONE
    error "lsort \"a \{b\"" {unmatched open brace in list} {TCL VALUE LIST BRACE}
    difference {Most errors have `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give a code such as `TCL LOOKUP INDEX option` or `TCL OPERATION LSORT INDEXFAILED` ([issue 730](https://github.com/beetlebugorg/ztcl/issues/730)).}

    option -ascii {
        type flag
        summary {Compares the elements as text; the default type.}
        description {Compares the text of two elements by the code point of each character, so each uppercase ASCII letter comes before each lowercase one, and `10` comes before `9`.}
        example {lsort -ascii {b B a A}} {A B a b}
        example {lsort {10 9 100}} {10 100 9}
        noerrors {Each value has a text, so each list sorts.}
    }
    option -dictionary {
        type flag
        summary {Compares the elements in dictionary order: no case, and runs of digits as numbers.}
        description {Compares the text of two elements with no regard to case, and a run of digits as an integer, so `a2` comes before `a10`. When two elements are the same with no regard to case, an uppercase letter comes before its lowercase one.}
        example {lsort -dictionary {a10 a2 A1}} {A1 a2 a10}
        example {lsort -dictionary {b B a A}} {A a B b}
        example {lsort -dictionary {x1.5 x1.10}} {x1.5 x1.10}
        noerrors {Each value has a text, so each list sorts.}
    }
    option -integer {
        type flag
        summary {Compares the elements as integers.}
        description {Each element must be an integer, in any form of Tcl, such as `0x10`. Equal integers in a different form, such as `1` and `01`, compare as equal.}
        example {lsort -integer {10 9 100}} {9 10 100}
        example {lsort -integer {0x10 9}} {9 0x10}
        error {lsort -integer {10 x}} {expected integer but got "x"} {TCL VALUE NUMBER}
    }
    option -real {
        type flag
        summary {Compares the elements as floating-point numbers.}
        description {Each element must be a number. The elements keep their form in the result: `1e2` stays `1e2`.}
        example {lsort -real {1.5 1e1 -2}} {-2 1.5 1e1}
        example {lsort -real {1e2 99.5}} {99.5 1e2}
        error {lsort -real {1 x}} {expected floating-point number but got "x"} NONE
    }
    option -command {
        value SCRIPT
        type {command prefix}
        summary {Compares two elements with a command.}
        description {Calls SCRIPT with two elements added as arguments. Its result must be an integer: negative when the first element comes first, 0 when they are equal, and positive when the second comes first. An error of the command stops the sort with that error.}
        example {
            proc cmp {a b} {expr {[string length $a] - [string length $b]}}
            lsort -command cmp {ccc a bb}
        } {a bb ccc}
        example {lsort -command {apply {{a b} {expr {$b - $a}}}} {1 3 2}} {3 2 1}
        error {
            proc bad {a b} {return x}
            lsort -command bad {a b}
        } {-compare command returned non-integer result} NONE
        error {lsort -command nocmd {a b}} {invalid command name "nocmd"} {TCL LOOKUP COMMAND nocmd}
    }
    option -increasing {
        type flag
        summary {Sorts from the smallest element to the largest; the default.}
        description {Puts the element that compares smallest first.}
        example {lsort -increasing {a c b}} {a b c}
        noerrors {A flag has no value to check.}
    }
    option -decreasing {
        type flag
        summary {Sorts from the largest element to the smallest.}
        description {Puts the element that compares largest first. Equal elements keep their order also in this direction.}
        example {lsort -decreasing {a c b}} {c b a}
        example {lsort -indices -decreasing {c a b}} {0 2 1}
        noerrors {A flag has no value to check.}
    }
    option -nocase {
        type flag
        summary {Compares the text with no regard to case.}
        description {With `-ascii` (the default), compares the letters as lowercase. Elements that are equal with no regard to case keep their order.}
        example {lsort -nocase {b B a A}} {a A b B}
        example {lsort -unique -nocase {b B a}} {a B}
        noerrors {A flag has no value to check.}
    }
    option -unique {
        type flag
        summary {Keeps one element of each group of equal elements.}
        description {Of each group of elements that compare equal, the result keeps the last one in LIST. With `-integer`, `1` and `01` are equal, so one of them goes away.}
        example {lsort -unique {b a b a}} {a b}
        example {lsort -integer -unique {1 01 2}} {01 2}
        example {lsort -indices -unique {b a b}} {1 2}
        noerrors {A flag has no value to check.}
    }
    option -indices {
        type flag
        summary {Gives the indexes of the elements in sorted order.}
        description {Gives the index in LIST of each element of the sorted result, in place of the element.}
        example {lsort -indices {c a b}} {1 2 0}
        noerrors {A flag has no value to check.}
    }
    option -index {
        value INDEX
        type {index, or a list of indexes}
        summary {Compares an element of each element in place of the whole element.}
        description {Each element of LIST is a list, and the sort compares its element at INDEX, or at the path of a list of indexes. Each element must have that index. The result has the whole elements.}
        example {lsort -index 1 -decreasing {{a 1} {b 3} {c 2}}} {{b 3} {c 2} {a 1}}
        example {lsort -index end {{a 1} {b 0}}} {{b 0} {a 1}}
        example {lsort -index {1 0} {{a {z 1}} {b {y 2}}}} {{b {y 2}} {a {z 1}}}
        error {lsort -index 1 {{a 1} {b}}} {element 1 missing from sublist "b"} NONE
    }
    option -stride {
        value N
        type {integer, 2 or more}
        summary {Sorts groups of N elements.}
        description {The list is groups of N elements, and its length must be a multiple of N. The sort compares the first element of each group, or the element of `-index` in the group, and moves each group whole.}
        example {lsort -stride 2 {b 2 a 1}} {a 1 b 2}
        example {lsort -stride 2 -index 1 {b 2 a 1}} {a 1 b 2}
        error {lsort -stride 3 {a b}} {list size must be a multiple of the stride length} NONE
        error {lsort -stride 1 {b a}} {stride length must be at least 2} NONE
        error {lsort -stride 2 -index 2 {a b}} {when used with "-stride", the leading "-index" value must be within the group} NONE
    }
}
