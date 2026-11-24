# SPDX-License-Identifier: BSD-2-Clause
# The native stack of 500 levels of proc calls. Only the suite runner
# has `testnativedepth`. tools/jit-diff.sh runs it with and without the
# JIT and checks that the JIT uses no more native stack.
proc down {n} {
    if {$n == 0} { return [testnativedepth] }
    set d [down [expr {$n - 1}]]
    return $d
}
down 2
down 2
puts [down 500]
