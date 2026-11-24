# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction bin_vi.
proc f {a} { return [list [expr {$a + 1}] [expr {$a - 7}] [expr {$a * 3}] [expr {$a >= 2}] [expr {$a % 3}] [expr {$a << 2}]] }
puts [f 5]
puts [list [catch {f 2.5} m] $m]
puts [f 9223372036854775807]
