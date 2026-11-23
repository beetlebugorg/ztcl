# SPDX-License-Identifier: BSD-2-Clause
# Memory test: a TclOO method adds to a variable of the object.
# The pass count is the first word of argv. The memory must stay flat when it grows.
oo::class create Counter {
    variable total
    constructor {} {
        set total 0
    }
    method add {k} {
        incr total $k
    }
    method total {} {
        return $total
    }
}
proc go {n} {
    set o [Counter new]
    for {set i 0} {$i < $n} {incr i} {
        $o add 3
    }
    return [$o total]
}
puts [go [lindex $argv 0]]
