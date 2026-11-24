# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction append.
proc f {} { set s {}; for {set i 0} {$i < 4} {incr i} { append s "x$i," }; append s end; return $s }
puts [f]
puts [f]
