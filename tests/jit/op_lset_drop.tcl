# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction lset_drop.
proc f {} { set l [lrepeat 5 0]; for {set i 0} {$i < 5} {incr i} { lset l $i $i }; return $l }
puts [f]
puts [f]
