# SPDX-License-Identifier: BSD-2-Clause
# Differential test: tailcall from compiled code.
proc g {x} { return [expr {$x * 3}] }
proc f {x} { set y [expr {$x + 1}]; tailcall g $y }
proc count {n acc} { if {$n == 0} { return $acc }; tailcall count [expr {$n - 1}] [expr {$acc + $n}] }
puts [f 4]
puts [count 200 0]
