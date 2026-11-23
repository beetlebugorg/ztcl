# SPDX-License-Identifier: BSD-2-Clause
# Memory test: binary encode base64 of 131072 bytes.
# The pass count is the first word of argv. The memory must stay flat when it grows.
proc go {n} {
    set str [string repeat a 131072]
    set sum 0
    for {set i 0} {$i < $n} {incr i} {
        incr sum [string length [binary encode base64 $str]]
    }
    return $i
}
puts [go [lindex $argv 0]]
