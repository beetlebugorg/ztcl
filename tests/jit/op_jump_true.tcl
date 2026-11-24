# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction jump_true.
proc f {a b} { return [expr {$a || $b}] }
puts [list [f 0 0] [f 1 0] [f 0 true] [f no 3]]
