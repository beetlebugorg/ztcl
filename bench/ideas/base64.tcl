# SPDX-License-Identifier: BSD-2-Clause
# Encodes or decodes one text of base64 or hex many times.
#   ztcl bench/ideas/base64.tcl encode|decode|hexenc|hexdec SIZE COUNT
# Count the time of the process (perf stat -e task-clock) and divide
# SIZE * COUNT by it. The setup is one pass over the text.
lassign $argv mode size count
set s [string repeat a $size]
set e [binary encode base64 $s]
set h [binary encode hex $s]
set n 0
switch -- $mode {
    encode { for {set i 0} {$i < $count} {incr i} { incr n [string length [binary encode base64 $s]] } }
    decode { for {set i 0} {$i < $count} {incr i} { incr n [string length [binary decode base64 $e]] } }
    hexenc { for {set i 0} {$i < $count} {incr i} { incr n [string length [binary encode hex $s]] } }
    hexdec { for {set i 0} {$i < $count} {incr i} { incr n [string length [binary decode hex $h]] } }
}
puts $n
