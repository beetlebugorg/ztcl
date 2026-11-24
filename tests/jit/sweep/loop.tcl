# SPDX-License-Identifier: BSD-2-Clause
# Step limit sweep.
proc f {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s $i; set t [expr {$s % 7}] }; return $s }
puts [f 40]
puts [f 40]
