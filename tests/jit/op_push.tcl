# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction push.
proc f {} { set a 5; set b {x y}; return [list $a $b 3.5] }
puts [f]
puts [f]
