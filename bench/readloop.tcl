# SPDX-License-Identifier: BSD-2-Clause
# 200 000 passes of llength and lindex on a string of 100 words.
proc run {} {
    set s [string trim [string repeat "alpha beta gamma delta " 25]]
    set t 0
    for {set i 0} {$i < 200000} {incr i} {
        set n [llength $s]
        incr t [string length [lindex $s [expr {$i % $n}]]]
    }
    return $t
}
puts [run]
