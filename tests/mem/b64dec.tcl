# SPDX-License-Identifier: BSD-2-Clause
# Memory test: binary decode base64 of a 174764 byte text.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set enc [binary encode base64 [string repeat a 131072]]
    set sum 0
    for {set i 0} {$i < $n} {incr i} {
        incr sum [string length [binary decode base64 $enc]]
    }
    return $i
}
puts [go [lindex $argv 0]]
