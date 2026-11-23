# SPDX-License-Identifier: BSD-2-Clause
# Memory test: a proc returns a list, and lassign takes it apart.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc f {tape pos} {
    return [list $tape $pos]
}
proc go {n} {
    set tape [lrepeat 100 0]
    set pos 0
    for {set i 0} {$i < $n} {incr i} {
        lassign [f $tape $pos] tape pos
    }
    return $i
}
puts [go [lindex $argv 0]]
