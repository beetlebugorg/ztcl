# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction lset.
proc f {} { set l {a b c}; set r [lset l 1 X]; return [list $r $l] }
puts [f]
proc g {} { set l {a b}; lset l 5 x }
puts [list [catch {g} m] $m]
