# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction ret.
proc f {x} { if {$x} { return early }; return late }
puts [list [f 1] [f 0]]
