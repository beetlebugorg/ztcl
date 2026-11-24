# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction dict_update_drop.
proc f {} { set d {}; for {set i 0} {$i < 20} {incr i} { dict incr d [expr {$i % 3}] }; dict set d x y; return $d }
puts [f]
puts [f]
