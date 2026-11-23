# SPDX-License-Identifier: BSD-2-Clause
# Memory test: a coroutine yields a new string in each pass.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    coroutine gen apply {{} {
        set i 0
        while 1 {
            yield x$i
            incr i
        }
    }}
    for {set i 0} {$i < $n} {incr i} {
        set s [gen]
    }
    return $s
}
puts [go [lindex $argv 0]]
