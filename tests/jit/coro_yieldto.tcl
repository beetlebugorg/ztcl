# SPDX-License-Identifier: BSD-2-Clause
# Differential test: yield in lsort -command, the codes of the end of a
# coroutine, the namespace of its command, and yieldto after a delete.
proc cmp {a b} { set r [catch yield m]; return [expr {$r ? 1 : -1}] }
puts [coroutine c1 lsort -command cmp {d a c b}]
set r {}
foreach code {0 1 2 3 4 5} { lappend r [catch {coroutine c2 return -level 0 -code $code}] }
puts $r
proc a {} { return global }
namespace eval ns1 { proc a {} { return local } }
puts [namespace eval ns1 { coroutine c3 a }]
proc gone {} { rename [info coroutine] {}; return <[info coroutine]> }
puts [coroutine c4 gone]
namespace eval q {}
proc q::body {} {
    for {set i 0} {$i < 50} {incr i} { incr s $i }
    yield $s
    yieldto ::return -level 0 done
}
puts [coroutine c5 q::body]
namespace delete q
namespace eval q {}
puts [list [catch c5 m] $m]
proc body2 {} { yield first; yieldto ::return -level 0 second }
puts [list [coroutine c6 body2] [c6]]
# inject and corotype, with a body that the JIT compiles.
proc counter {} { set n 0; while 1 { for {set k 0} {$k < 20} {incr k} { incr n $k }; yield $n } }
coroutine c7 counter
set ::seen none
tcl::unsupported::inject c7 set ::seen injected
puts [list [c7] $::seen [tcl::unsupported::corotype c7]]
