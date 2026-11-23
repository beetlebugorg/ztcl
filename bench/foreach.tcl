# SPDX-License-Identifier: BSD-2-Clause
# Sums a list of 100 000 integers with foreach, ten times.
proc go {} {
    set l {}
    for {set i 0} {$i < 100000} {incr i} { lappend l $i }
    set s 0
    for {set k 0} {$k < 10} {incr k} {
        foreach x $l { incr s $x }
    }
    return $s
}
puts [go]
