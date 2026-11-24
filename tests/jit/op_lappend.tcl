# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction lappend.
proc f {} { set l {}; for {set i 0} {$i < 5} {incr i} { lappend l $i }; set s abc; lappend s d; return [list $l $s] }
puts [f]
puts [f]
