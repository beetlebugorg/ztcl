# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction lassign.
proc f {l} { set r [lassign $l a b]; return [list $a $b $r] }
puts [f {1 2 3 4}]
puts [f {1}]
