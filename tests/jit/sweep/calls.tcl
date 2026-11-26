# SPDX-License-Identifier: BSD-2-Clause
# Compute limit sweep.
proc g {x} { return [expr {$x * 2}] }
proc f {} { set r {}; foreach x {1 2 3 4 5 6} { lappend r [g $x] }; return $r }
puts [f]
puts [f]
