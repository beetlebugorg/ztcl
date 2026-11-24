# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction incr.
proc f {} { set a 1; set b [incr a 5]; set c [incr a -10]; return [list $a $b $c] }
puts [f]
proc g {} { set x 9223372036854775806; incr x; incr x; return $x }
puts [g]
proc h {} { set y abc; incr y }
puts [list [catch {h} m] $m]
