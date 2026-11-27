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
# An array element owns its dict or list after a dict set or an lset
# whose result is dropped. Each read form of the element below gives a
# copy that a later write must not change.
# The order of `array get` is not the order of Tcl, so the output sorts it.
proc sorted {l} { lsort -stride 2 -index 0 $l }
proc elemreads {} {
    set a(x) {k0 0 k1 1}
    set a(l) {0 0 0}
    set keep {}
    for {set i 0} {$i < 26} {incr i} {
        dict set a(x) k[expr {$i % 3}] $i
        dict set a(x) n m $i
        lset a(l) [expr {$i % 3}] $i
        lset a(l) 1 0 $i
        switch [expr {$i % 13}] {
            0 { lappend keep $a(x) $a(l) }
            1 { set c $a(x); lappend keep $c }
            2 { lappend keep [sorted [array get a]] }
            3 { foreach {k v} [array get a l] { lappend keep $v } }
            4 { upvar 0 a(x) y; lappend keep $y }
            5 { lappend keep [dict get $a(x) n] [lindex $a(l) 1] }
            6 { array set b [array get a]; lappend keep $b(x) }
            7 { lappend keep [set a(x)] [set a(l)] }
            8 { set n x; lappend keep $a($n) }
            9 { lappend a(l) 9; lappend keep [lappend a(l) 8] }
            10 { foreach k [lsort [array names a]] { lappend keep $k $a($k) } }
            11 { lappend keep [append a(s) $i] }
            12 { set a(x) [dict create fresh $i]; lappend keep $a(x) }
        }
        dict set a(x) k[expr {$i % 3}] -$i
        dict set a(x) n m -$i
        lset a(l) [expr {$i % 3}] -$i
    }
    list [sorted [array get a]] $keep
}
puts [elemreads]
proc elemlink {} {
    set a(x) {p 1}
    upvar 0 a(x) e
    set keep {}
    for {set i 0} {$i < 6} {incr i} {
        dict set a(x) p $i
        lappend keep $e
        dict set e q $i
        dict set a(x) p -$i
    }
    list $a(x) $e $keep
}
puts [elemlink]
proc elemtrace {} {
    set a(x) {p 1}
    set ::seen {}
    for {set i 0} {$i < 6} {incr i} {
        if {$i == 3} { trace add variable a read {apply {{n i op} { upvar 1 $n v; lappend ::seen $v($i) }}} }
        dict set a(x) p $i
        set t $a(x)
        dict set a(x) p -$i
    }
    list $a(x) $::seen
}
puts [elemtrace]
proc elemswap {} {
    set a(x) {p 1}
    set a(y) {p 1}
    set g {}
    for {set i 0} {$i < 8} {incr i} {
        dict set a(x) p $i
        dict set a(y) p $i
        if {$i == 4} { set g $a(y); unset a(y); set a(y) {p 1} }
        if {$i == 5} { unset a; set a(x) {p 1}; set a(y) $g }
    }
    list [sorted [array get a]] $g [catch {dict set a(z) p 1} m] $m [catch {lset a(x) 9 1} m] $m [catch {dict set a(x) p q 1} m] $m
}
puts [elemswap]
proc elemglobal {} {
    global G
    for {set i 0} {$i < 5} {incr i} { dict set G(d) k $i; lset G(l) 0 $i; set ::Gk($i) $G(d) }
}
set G(d) {k 0}
set G(l) {0 1}
elemglobal
puts [list [sorted [array get G]] [sorted [array get Gk]]]
