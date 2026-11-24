# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction invoke.
proc g {a b} { return [expr {$a + $b}] }
proc f {} { set x [g 1 2]; set y [string toupper abc]; return [list $x $y [llength [list 1 2 3]]] }
puts [f]
puts [f]
