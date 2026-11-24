# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `namespace eval` with a loop.
namespace eval ns {
    variable total 0
    for {set i 0} {$i < 30} {incr i} {
        incr total $i
        if {$total > 200} break
    }
    variable list {}
    foreach w {x y z} { lappend list $w$i }
}
puts [list $ns::total $ns::i $ns::list]
namespace eval ns { set total [expr {$total * 2}]; while {$total > 100} { incr total -77 } }
puts $ns::total
namespace eval ns2 { proc llength {l} { return many }; for {set k 0} {$k < 3} {incr k} { lappend r [llength {1 2}] } }
puts $ns2::r
