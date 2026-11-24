# SPDX-License-Identifier: BSD-2-Clause
# Differential test: coroutines that yield from compiled code.
proc gen {n} {
    yield [info coroutine]
    for {set i 0} {$i < $n} {incr i} { yield [expr {$i * $i}] }
    return done
}
coroutine c1 gen 4
set r {}
for {set k 0} {$k < 5} {incr k} { lappend r [c1] }
puts $r
proc acc {} { set s 0; while 1 { set v [yield $s]; if {$v eq "stop"} break; incr s $v }; return final$s }
coroutine c2 acc
foreach v {1 2 3 stop} { set last [c2 $v] }
puts $last
proc pump {} { set r [list [coroutine c3 apply {{} { yield 1; yield 2; return 3 }}] [c3] [c3]]; return $r }
puts [pump]
