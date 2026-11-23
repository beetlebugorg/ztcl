# SPDX-License-Identifier: BSD-2-Clause
# Counts keys in a dict in a loop with dict incr and dict get.
proc go {n} {
    set d {}
    for {set i 0} {$i < $n} {incr i} {
        dict incr d [expr {$i % 100}]
    }
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        incr s [dict get $d [expr {$i % 100}]]
    }
    return $s
}
puts [go 200000]
