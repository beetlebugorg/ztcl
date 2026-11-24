# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction foreach_init.
proc f {l} { set r {}; foreach x $l { lappend r $x }; return $r }
puts [f {a b c}]
puts [f "x  y"]
set bad "a \{b"
puts [list [catch {f $bad} m] $m]
