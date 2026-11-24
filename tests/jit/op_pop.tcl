# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction pop.
proc f {} { set a 1; set b 2; incr a; return $a }
puts [f]
puts [f]
