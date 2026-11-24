# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction to_bool.
proc f {a b} { return [list [expr {$a && $b}] [expr {$a || $b}]] }
puts [list [f 1 5] [catch {f 0 x} m] $m [f yes no] [f 2 0]]
