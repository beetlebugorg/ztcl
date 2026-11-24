# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction binary.
proc f {a b} { return [list [expr {($a + 1) * ($b - 1)}] [expr {($a + 0) < ($b + 0)}] [expr {($a + 0) / ($b + 0)}] [expr {($a + 0) % ($b + 0)}] [expr {($a + 0) ** 2}]] }
puts [f 7 3]
puts [f -7 2]
puts [f 9223372036854775807 2]
puts [list [catch {f 1 0} m] $m]
