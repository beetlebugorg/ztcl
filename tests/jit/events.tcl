# SPDX-License-Identifier: BSD-2-Clause
# jit-diff-flags: --allow event
# Differential test: event scripts run at the global level.
set n 0
proc tick {k} { global n; set n [expr {$n + $k}]; if {$k < 5} { after 0 [list tick [expr {$k + 1}]] } else { set ::done 1 } }
after 0 {tick 1}
vwait done
puts $n
