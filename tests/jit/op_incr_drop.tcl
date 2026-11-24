# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction incr_drop.
proc f {} { set i 0; incr i; incr i 2; incr i -1; return $i }
puts [f]
puts [f]
