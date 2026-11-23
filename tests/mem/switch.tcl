# SPDX-License-Identifier: BSD-2-Clause
# Memory test: switch -exact on a word.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set op INC
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        switch -exact -- $op {INC {incr s} MOVE {incr s 2}}
    }
    return $i
}
puts [go [lindex $argv 0]]
