# SPDX-License-Identifier: BSD-2-Clause
# jit-diff-flags: --allow interp
# Differential test: a child interpreter runs its own procs.
interp create c
c eval { proc f {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s $i }; return $s } }
puts [c eval {f 10}]
puts [c eval {f 100}]
interp alias {} cf c f
puts [cf 5]
interp delete c
