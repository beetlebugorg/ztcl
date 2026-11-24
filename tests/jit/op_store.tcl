# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction store.
proc f {} { set a [set b 7]; return [list $a $b] }
puts [f]
puts [f]
