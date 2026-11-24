# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the limit of nested proc calls.
proc down {n} { if {$n == 0} { return 0 }; return [expr {[down [expr {$n - 1}]] + 1}] }
puts [down 300]
puts [catch {down 100000} m]
puts $m
