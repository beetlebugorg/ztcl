# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction str_eq_jump.
proc f {x} { switch -exact -- $x { a { return A } b - c { return BC } default { return other } } }
puts [list [f a] [f b] [f c] [f 5] [f {}]]
