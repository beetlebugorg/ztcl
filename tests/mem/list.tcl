# SPDX-License-Identifier: BSD-2-Clause
# Memory test: a new list of three items in each pass.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set l {}
    for {set i 0} {$i < $n} {incr i} {
        set l [list $i $i $i]
    }
    return $i
}
puts [go [lindex $argv 0]]
