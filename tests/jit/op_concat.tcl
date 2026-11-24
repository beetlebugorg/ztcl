# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction concat.
proc f {a b} { set s "$a-$b-[expr {$a + 1}]"; return $s }
puts [f 1 2]
puts [list [catch {f x y} m] $m]
