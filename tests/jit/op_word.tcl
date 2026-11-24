# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction word.
proc f {} { array set a {k 7}; set i k; set r $a($i); return [list $r $a(k)] }
puts [f]
puts [f]
