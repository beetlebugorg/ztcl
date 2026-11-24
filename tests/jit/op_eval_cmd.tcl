# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction eval_cmd.
proc f {} { set l {a b}; set r [list {*}$l c]; return $r }
puts [f]
puts [f]
