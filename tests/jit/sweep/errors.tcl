# SPDX-License-Identifier: BSD-2-Clause
# Step limit sweep.
proc f {n} { set r {}; for {set i 0} {$i < $n} {incr i} { lappend r [catch {if {$i % 3 == 0} { error e$i }; set i} m] $m }; return $r }
puts [f 12]
