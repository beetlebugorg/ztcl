# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction number_form.
proc f {a} { return [expr {$a}] }
puts [list [f 0x10] [f 1e3] [f abc] [f 007] [f { 5 }]]
