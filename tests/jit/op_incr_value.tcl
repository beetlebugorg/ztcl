# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction incr_value.
proc f {by} { set a 10; incr a $by; return $a }
puts [list [f 3] [f -20] [f 0x10]]
puts [list [catch {f x} m] $m]
