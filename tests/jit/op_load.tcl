# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction load.
proc f {} { set a 4; set b $a; set c "$a$b"; return [list $a $b $c] }
puts [f]
puts [f]
