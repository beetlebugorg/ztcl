# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction node.
proc f {x} { return [list [expr {sin(0) + abs($x)}] [expr {max($x, 3)}] [expr {"$x" eq "2"}]] }
puts [f 2]
puts [f -5]
