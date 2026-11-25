# SPDX-License-Identifier: BSD-2-Clause
# Differential test: lmap compiled with the foreach loop.
proc a {} {lmap x {1 2 3} {if {$x==2} continue; expr {$x*2}}}
proc b {} {lmap x {1 2 3} {if {$x==3} break; set x}}
proc c {} {lmap {x y} {1 2 3} {list $x $y}}
proc d {} {lmap x {} {set x}}
proc e {} {lmap x {1 2} {}}
proc g {} {set r [lmap x {1 2} {return early}]; return late}
proc h {} {lmap x {a b} {set x}; set x}
proc i {} {lmap x {1 2 3} {incr x}}
proc j {} {set n 0; lmap x {1 2} {incr n; continue}}
proc k {} {lmap x [list 1 2] y {a b c} {string cat $x $y}}
proc m {} {lmap x {1 {2 3}} {set x}}
proc n {} {lmap y {1 2} {lmap z {a b} {list $y $z}}}
proc o {} {set s 0; foreach w {1 2} {lappend s [lmap v {3 4} {expr {$v*$w}}]}; set s}
proc p {l} {set t 0; for {set q 0} {$q < 50} {incr q} {incr t [llength [lmap v $l {if {$v % 3} {set v} else continue}]]}; set t}
foreach pr {a b c d e g h i j k m n o} {puts "$pr <[$pr]>"}
puts "p <[p {1 2 3 4 5 6 7 8 9}]>"
puts "f <[catch {lmap x {1 2} {error boom$x}} msg]> $msg"
puts [lmap x {1 2} {expr {$x+1}}]
set bad "a \{b"; catch {lmap x $bad {set x}} msg; puts $msg
proc r {} {lmap x {1 2} {set x}}
rename lmap _l; proc lmap args {return redef}; puts [r]; rename lmap {}; rename _l lmap; puts [r]
