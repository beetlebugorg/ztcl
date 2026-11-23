# SPDX-License-Identifier: BSD-2-Clause
# Memory test: lset on a list of 100 items.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set tape [lrepeat 100 0]
    for {set i 0} {$i < $n} {incr i} {
        lset tape 3 5
    }
    return $i
}
puts [go [lindex $argv 0]]
