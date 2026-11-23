# SPDX-License-Identifier: BSD-2-Clause
# Memory test: a new string in each pass.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set s {}
    for {set i 0} {$i < $n} {incr i} {
        set s x$i
    }
    return $i
}
puts [go [lindex $argv 0]]
