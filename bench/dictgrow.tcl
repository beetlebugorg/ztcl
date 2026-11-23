# SPDX-License-Identifier: BSD-2-Clause
# Grows one dict with new keys, then reads each key.
proc go {n} {
    set d {}
    for {set i 0} {$i < $n} {incr i} {
        dict set d key$i $i
    }
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        incr s [dict get $d key$i]
    }
    return [list [dict size $d] $s]
}
puts [go 200000]
