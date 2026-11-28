# The command reference: lseq. The format is in
# docs/dev/reference-format.md.

command lseq {
    area lists
    since 1.0.0-beta.1
    tcl 9.1
    synopsis {lseq COUNT}
    synopsis {lseq START ?to|..? END ??by? STEP?}
    synopsis {lseq START count COUNT ??by? STEP?}
    summary {Makes a list of numbers in an arithmetic series.}
    description {
        Gives a list of numbers from START, each one STEP more than the one before. The three forms are:

        - `lseq COUNT`: the COUNT integers from 0 to COUNT-1. A COUNT of 0 or less gives an empty list.
        - `lseq START END ?STEP?`: the numbers from START up to END, or down to it. The list stops at the last number that does not pass END, and END is in the list when the series meets it. `to` and `..` before END are optional words.
        - `lseq START count COUNT ?STEP?`: COUNT numbers from START.

        `by` before STEP is an optional word. The default STEP is 1, or -1 when END is less than START. A STEP that goes away from END gives an empty list, and a STEP of 0 gives START once.

        Each number is an integer when each argument is an integer, in any form of Tcl such as `0x10`. With a double, each number is a double rounded to the most decimal places of the arguments, so `lseq 0 1 0.25` gives `0.0 0.25 0.5 0.75 1.0`. An argument is a number: an expression such as `1+1` is an error.
    }
    returns {The list of numbers.}
    see {lrepeat for foreach}
    difference {tclsh 9.1 makes a list that computes each element when a script reads it, so a long series uses little memory. ztcl makes the whole list, with the list limit of `lrepeat`.}
    argument COUNT {
        type integer
        summary {The count of numbers.}
    }
    argument START {
        type number
        summary {The first number.}
    }
    argument END {
        type number
        summary {The bound of the series: the last number when the series meets it.}
    }
    argument STEP {
        type number
        optional
        default {1, or -1 when END is less than START}
        summary {The difference between two numbers in a row.}
    }
    example {lseq 5} {0 1 2 3 4}
    example {lseq 1 5} {1 2 3 4 5}
    example {lseq 5 1} {5 4 3 2 1}
    example {lseq 1 to 9 by 3} {1 4 7}
    example {lseq 1 .. 4} {1 2 3 4}
    example {lseq 10 count 3} {10 11 12}
    example {lseq 10 count 3 by 2} {10 12 14}
    example {lseq 0 1 0.25} {0.0 0.25 0.5 0.75 1.0}
    example {lseq 0 1 by 0.3} {0.0 0.3 0.6 0.9}
    example {lseq 1 10 -1} {}
    example {lseq 0x10 0x12} {16 17 18}
    error {lseq x} {expected number but got "x"} {TCL VALUE NUMBER}
    error {lseq 1+1} {expected number but got "1+1"} {TCL VALUE NUMBER}
    error {lseq 1 to} {missing "to" value.} NONE
    error {lseq 1 2 3 4 5} {wrong # args: should be "lseq n ??op? n ??by? n??"} {TCL WRONGARGS}
}
