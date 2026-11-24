# SPDX-License-Identifier: BSD-2-Clause
# Sums one million products of doubles with expr in a loop. A literal
# word is a string, so x gets its double from expr.
proc dsum {n} {
    set s 0.0
    set x [expr {1.5}]
    for {set i 0} {$i < $n} {incr i} {
        set s [expr {$s + $x * 0.5}]
    }
    return $s
}
puts [dsum 1000000]
