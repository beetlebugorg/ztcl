# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `eval` of one string 1000 times.
set code {incr k; if {$k % 3 == 0} { append out . } else { set last [expr {$k * $k}] }}
set k 0
set out {}
for {set r 0} {$r < 1000} {incr r} { eval $code }
puts [list $k [string length $out] $last]
proc inproc {} { set k 0; set out {}; for {set r 0} {$r < 1000} {incr r} { eval {incr k; if {$k % 3 == 0} { append out . } else { set last [expr {$k * $k}] }} }; return [list $k [string length $out] $last] }
puts [inproc]
