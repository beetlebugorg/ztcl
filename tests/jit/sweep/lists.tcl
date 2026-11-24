# SPDX-License-Identifier: BSD-2-Clause
# Step limit sweep.
proc f {} { set l {}; for {set i 0} {$i < 20} {incr i} { lappend l $i }; set s 0; foreach x $l { incr s $x }; lset l 3 x; lassign $l a b; dict set d k $s; return [list $s $a $b $d [llength $l]] }
puts [f]
