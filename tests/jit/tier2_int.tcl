# SPDX-License-Identifier: BSD-2-Clause
# Integer loops for tier 2: overflow, compares, break, continue, a loop
# in an expression, and a slot that becomes a link after the compile.
proc sum {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i * 3 - 1}] }; return $s }
proc over {} { set s 9223372036854775000; for {set i 0} {$i < 2000} {incr i} { set s [expr {$s + 1}] }; list $s $i }
proc neg {} { set s -9223372036854775000; for {set i 0} {$i < 2000} {incr i} { incr s -1 }; set s }
proc mul {} { set s 1; set k 0; while {$k < 80} { incr k; set s [expr {$s * 3}] }; list $s $k }
proc bc {} { set s 0; for {set i 0} {$i < 200} {incr i} { if {$i > 150} { break }; if {$i % 3 == 0} { continue }; incr s $i }; list $s $i }
proc cmp {} { set a 0; set b 0; for {set i -50} {$i <= 50} {incr i 2} { if {$i >= 0 && $i != 10} { incr a }; if {!($i < -10)} { incr b $i } }; list $a $b }
proc inexpr {} { set i 0; set t [expr {[while {$i < 20} { incr i }] eq ""}]; list $t $i }
proc lk {mode} { if {$mode} { upvar 1 g x } else { set x 0 }; for {set i 0} {$i < 50} {incr i} { incr x }; return $x }
proc str {} { set n 10; set s 0; for {set i 0} {$i < 2000} {incr i} { incr s; if {$i == 1500} { set s abc; break } }; list $s $i }
set g 5
puts [list [sum 3000] [over] [neg] [mul] [bc] [cmp] [inexpr] [lk 0] [lk 1] [lk 0] $g [str]]
