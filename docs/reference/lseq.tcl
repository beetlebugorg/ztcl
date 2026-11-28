# Converted by tools/refdoc.tcl convert from lists.txt.

command lseq {
    area lists
    since TODO
    synopsis {lseq count}
    synopsis {lseq start ?to|..? end ??by? step?}
    synopsis {lseq start count count ??by? step?}
    summary {A list of numbers from start, each one step more than the one before.}
    description {A list of numbers from start, each one step more than the one before. With an end, the list stops at the last number that does not pass end. The default step is 1, or -1 when end is less than start. With doubles, each number is rounded to the most decimal places of the arguments.}
    tcl {9.1}
    difference {tclsh 9.1 makes a list that computes each element when a script reads it, so a long series uses little memory. ztcl makes the whole list, with the list limit of `lrepeat`.}
    example {lseq 5} {0 1 2 3 4}
    example {lseq 1 to 9 by 3} {1 4 7}
    example {lseq 10 count 3} {10 11 12}
    example {lseq 0 1 0.25} {0.0 0.25 0.5 0.75 1.0}
    error {lseq x} {expected number but got "x"} {TCL VALUE NUMBER}
}
