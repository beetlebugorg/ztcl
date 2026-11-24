# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction jump_false.
proc f {x} { if {$x} {return t}; return f }
puts [list [f 0] [f 1] [f yes] [f off] [f 2.5]]
puts [list [catch {f maybe} m] $m]
