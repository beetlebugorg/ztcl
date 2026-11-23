# SPDX-License-Identifier: BSD-2-Clause
# Builds a string with append in a loop.
proc build {n} {
    set s ""
    for {set i 0} {$i < $n} {incr i} {
        append s "x$i,"
    }
    return [string length $s]
}
puts [build 500000]
