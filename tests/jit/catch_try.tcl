# SPDX-License-Identifier: BSD-2-Clause
# Differential test: catch and try around compiled code.
proc f {n} { if {$n > 2} { error "n=$n" } ; return [expr {$n * 10}] }
set r {}
for {set i 0} {$i < 5} {incr i} { lappend r [catch {f $i} m opts] $m [dict get $opts -code] }
puts $r
proc g {} {
    set log {}
    try { lappend log a; error boom } on error {msg} { lappend log "caught $msg" } finally { lappend log fin }
    try { lappend log b } finally { lappend log fin2 }
    return $log
}
puts [g]
puts [g]
proc h {} { try { return inner } finally { set x 1 } }
puts [h]
proc k {} { set r [catch { for {set i 0} {$i < 3} {incr i} { if {$i == 1} { error stop } } } m]; return [list $r $m $i] }
puts [k]
