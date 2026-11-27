# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `dict for` with two literal names and a literal
# body compiles to the loop of `foreach` on the pairs of the dict.
proc sum {d} {set s 0; dict for {k v} $d {incr s $v}; return $s}
proc keys {d} {set r {}; dict for {k v} $d {lappend r $k=$v}; return $r}
proc ctl {d} {
    set r {}
    dict for {k v} $d {
        if {$k eq "b"} continue
        if {$k eq "d"} break
        lappend r $k
    }
    list $r [dict for {k v} {} {}] [info exists k] $k $v
}
proc dup {} {set r {}; dict for {k v} {a 1 b 2 a 3} {lappend r $k $v}; return $r}
proc bad {d} {list [catch {dict for {k v} $d {}} m] $m}
proc err {} {catch {dict for {k v} {a 1} {error boom}} m o; list $m [dict get $o -errorcode]}
proc ret {} {dict for {k v} {a 1 b 2} {if {$k eq "b"} {return $v}}; return none}
proc change {} {set d {a 1 b 2}; set r {}; dict for {k v} $d {dict set d c 3; lappend r $k}; list $r $d}
proc arr {} {set r {}; dict for {k v} {a 1} {set x($k) $v}; array get x}
proc traced {} {
    set n 0
    trace add variable v write [list apply {{args} {upvar 1 n n; incr n}}]
    dict for {k v} {a 1 b 2 c 3} {}
    return $n
}
proc nested {} {set s 0; dict for {k d} {x {a 1 b 2} y {c 3}} {dict for {k2 v} $d {incr s $v}}; return $s}
proc lit {} {set r {}; dict for {k v} [dict create z 26 y 25] {lappend r $k}; return $r}
puts [sum {a 1 b 2 c 3}]
puts [keys {a 1 b 2}]
puts [ctl {a 1 b 2 c 3 d 4 e 5}]
puts [dup]
puts [bad {a 1 b}]
puts [bad "a \{"]
puts [err]
puts [ret]
puts [change]
puts [arr]
puts [traced]
puts [nested]
puts [lit]
set d {}
for {set i 0} {$i < 100} {incr i} {dict set d k$i $i}
puts [sum $d]
