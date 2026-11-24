# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction step.
proc f {} { set s 0; set i 0; while {$i < 50} { incr i; incr s $i }; return $s }
puts [f]
puts [f]
