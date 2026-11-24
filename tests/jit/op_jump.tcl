# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction jump.
proc f {x} { if {$x} { set r yes } else { set r no }; return $r }
puts [f 0]
