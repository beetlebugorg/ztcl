# Converted by tools/refdoc.tcl convert from lists.txt.

command lpop {
    area lists
    since TODO
    synopsis {lpop listVar ?index ...?}
    summary {Takes an element out of the list in a variable and gives it.}
    description {Takes an element out of the list in a variable and gives it. The default index is `end`. More indexes go into nested lists.}
    tcl {9.1}
    example {set l {a b c}; list [lpop l] $l} {c {a b}}
    example {set l {{a b} c}; list [lpop l 0 0] $l} {a {b c}}
    error {set l {}; lpop l} {index "end" out of range} {TCL VALUE INDEX OUTOFRANGE}
}
