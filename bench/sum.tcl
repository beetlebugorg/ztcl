# SPDX-License-Identifier: BSD-2-Clause
# Sums the integers below one million with expr in a loop.
proc sum {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        set s [expr {$s + $i}]
    }
    return $s
}
puts [sum 1000000]
