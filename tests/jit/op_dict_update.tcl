# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction dict_update.
proc f {} { set d {}; set r [dict incr d a]; lappend r [dict set d b 2]; lappend r [dict incr d a 5]; return $r }
puts [f]
puts [f]
