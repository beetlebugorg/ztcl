# SPDX-License-Identifier: BSD-2-Clause
# Differential test: a `while` body in `apply`.
puts [apply {{n} {
    set r {}
    set i 0
    while {$i < $n} { lappend r [expr {$i * $i}]; incr i; if {$i == 6} continue }
    return $r
}} 9]
set f {{x} { set acc 1; while {$x > 1} { set acc [expr {$acc * $x}]; incr x -1 }; return $acc }}
puts [list [apply $f 5] [apply $f 20] [apply $f 21]]
