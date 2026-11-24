# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction jf_vv.
proc f {a b} { set r {}; if {$a < $b} { lappend r lt }; if {$a == $b} { lappend r eq }; if {$a >= $b} { lappend r ge }; return $r }
puts [list [f 1 2] [f 2 2] [f 3 2] [f a b] [f 1.5 1.5]]
