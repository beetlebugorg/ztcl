# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `dict set`, `dict incr`, `dict lappend`, and `lset`
# keep the ownership of a variable that is not a slot when the result is
# dropped. Each copy of the value stays the same. The arm64 JIT job
# runs tests/jit/coroutine.tcl with no .out file, so this file has no
# coroutine.
set D {a 1 b 2}
dict set D a 10
set copy $D
dict set D a 11
dict incr D b
set L {1 2 3}
lset L 0 9
set lcopy $L
lset L 1 8
puts [list $copy $D $lcopy $L]
set inlist [list $D $L]
set arr(x) $D
dict set D c 3
lset L 2 7
puts [list $inlist $arr(x) $D $L [info exists D] [dict exists $D c]]
proc viaglobal {} {
    dict set ::D a 20
    set c $::D
    dict set ::D a 21
    lset ::L 0 5
    set l $::L
    lset ::L 0 6
    list $c $::D $l $::L
}
puts [viaglobal]
namespace eval ns {
    variable V {k 0}
    proc bump {n} {
        variable V
        set seen {}
        for {set i 0} {$i < $n} {incr i} {
            dict incr V k
            dict set V last $i
            if {$i == 1} { set seen $V }
        }
        list $seen $V
    }
}
puts [ns::bump 4]
puts $ns::V
proc viaup {name} { upvar 1 $name v; dict set v up 1; dict lappend v lst a; dict lappend v lst b }
viaup D
puts $D
set traced {}
trace add variable D write {apply {{args} {lappend ::traced w}}}
dict set D t 1
dict set D t 2
trace remove variable D write {apply {{args} {lappend ::traced w}}}
puts [list $traced [dict get $D t]]
set r [dict set D r 1]
puts [list $r $D]
set E {x 1}
dict set E y 2
puts [list [dict set E z 3] $E]
for {set i 0} {$i < 5} {incr i} { dict set D loop $i; lset L 0 $i }
puts [list $D $L]
unset D
dict set D fresh 1
dict set D fresh 2
puts $D
