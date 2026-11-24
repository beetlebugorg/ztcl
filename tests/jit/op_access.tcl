# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction access.
proc f {l s} { return [list [llength $l] [lindex $l 1] [lindex $l 9] [lindex $l end] [string length $s] [string index $s 1] [llength $s] [lindex $s 0]] }
puts [f {a b c} hello]
puts [f {} {}]
set bad "a \{b"
puts [list [catch {f $bad x} m] $m]
