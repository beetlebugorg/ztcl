# SPDX-License-Identifier: BSD-2-Clause
# Differential test: a redefined or renamed command inside compiled code.
proc f {n} {
    set r {}
    for {set i 0} {$i < $n} {incr i} {
        if {$i == 2} { rename lappend real_lappend; proc lappend {v x} { upvar 1 $v l; real_lappend l "<$x>" } }
        if {$i == 4} { rename lappend {}; rename real_lappend lappend }
        lappend r $i
    }
    return $r
}
puts [f 7]
puts [f 7]
proc g {} { set a 1; rename set real_set; proc set {args} { return "own set" }; real_set b [set a]; rename set {}; rename real_set set; return $b }
puts [g]
puts [g]
namespace eval ns { proc lappend {args} { return shadow } ; proc h {} { set l {}; lappend l x; return $l } }
puts [ns::h]
puts [ns::h]
