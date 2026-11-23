# SPDX-License-Identifier: BSD-2-Clause
# Memory test: lassign on a list of two words.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set x {INC 1}
    for {set i 0} {$i < $n} {incr i} {
        lassign $x op val
    }
    return $i
}
puts [go [lindex $argv 0]]
