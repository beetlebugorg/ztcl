# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction bin_vv.
proc f {a b} { return [list [expr {$a + $b}] [expr {$a - $b}] [expr {$a * $b}] [expr {$a < $b}] [expr {$a == $b}] [expr {$a % $b}] [expr {$a & $b}]] }
puts [f 6 4]
puts [list [catch {f 1.5 2} m] $m]
puts [f -9223372036854775808 -1]
