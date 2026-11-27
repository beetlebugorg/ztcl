# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `incr name $x` with a string step reads the step
# inline, with the parse and the errors of the command.
proc sum {l} {set s 0; foreach x $l {incr s $x}; return $s}
proc err {x} {set s 0; list [catch {incr s $x} m] $m $s}
proc unset_var {x} {list [incr n $x] [incr n $x]}
proc big {x} {set s 9223372036854775807; incr s $x}
proc traced {} {
    set n 0
    set s 1
    trace add variable s write [list apply {{args} {upvar 1 n n; incr n}}]
    foreach x [split "1 2 3"] {incr s $x}
    list $s $n
}
proc arr {} {set a(k) 1; foreach x [split "5 6"] {incr a(k) $x}; set a(k)}
puts [sum [split "1 2 3 4 5"]]
puts [sum [split "7 0x10 -3 +4 010"]]
puts [err abc]
puts [err 1.5]
puts [err ""]
puts [err " 12 "]
puts [unset_var 3]
puts [big 1]
puts [big [string trim " 1 "]]
puts [traced]
puts [arr]
