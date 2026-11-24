# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction foreach_next.
proc f {} { set r {}; foreach {a b} {1 2 3 4 5} { lappend r $a-$b }; foreach x {} { lappend r never }; return $r }
puts [f]
puts [f]
