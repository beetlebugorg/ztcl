# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction jf_vi.
proc f {a} { set r {}; for {set i $a} {$i < 5} {incr i} { lappend r $i }; if {$a != 3} { lappend r ne }; return $r }
puts [list [f 1] [f 3] [catch {f 4.5} m] $m]
