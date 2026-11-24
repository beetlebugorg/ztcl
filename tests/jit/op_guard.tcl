# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction guard.
proc f {} { set a 1; incr a; set l {}; lappend l $a; return $l }
puts [f]
rename lappend la
proc lappend {v args} { upvar 1 $v x; set x "own $args" }
puts [f]
