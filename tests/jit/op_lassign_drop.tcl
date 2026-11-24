# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction lassign_drop.
proc f {l} { lassign $l a b c; return [list $a $b $c] }
puts [f {x y}]
puts [f {1 2 3 4}]
