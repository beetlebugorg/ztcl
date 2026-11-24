# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction store_pop.
proc f {} { set a 1; set b 2; set c 3; return [expr {$a + $b + $c}] }
puts [f]
puts [f]
