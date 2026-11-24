# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction push_empty.
proc f {} { if {0} {set x 1}; set r [if {0} {}]; return [list $r [while {0} {}]] }
puts [f]
puts [f]
