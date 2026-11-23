# SPDX-License-Identifier: BSD-2-Clause
# Memory test: a new dict in each pass.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set d {}
    for {set i 0} {$i < $n} {incr i} {
        set d [dict create a $i]
    }
    return $i
}
puts [go [lindex $argv 0]]
