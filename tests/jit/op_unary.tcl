# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction unary.
proc f {a} { return [list [expr {-$a}] [expr {!$a}] [expr {~$a}] [expr {+$a}]] }
puts [f 5]
puts [f 0]
puts [list [catch {f x} m] $m]
