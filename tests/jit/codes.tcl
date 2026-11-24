# SPDX-License-Identifier: BSD-2-Clause
# Differential test: return, break, continue, and custom codes.
proc r {c} { return -code $c "v$c" }
set out {}
foreach c {ok error return 5 42} { lappend out [catch {r $c} m] $m }
foreach c {break continue} { lappend out [catch {r $c}] }
puts $out
proc loops {} {
    set s {}
    for {set i 0} {$i < 8} {incr i} {
        if {$i == 1} continue
        if {$i == 6} break
        lappend s $i
    }
    foreach x {a b c d} { if {$x eq "c"} break; lappend s $x }
    set k 0
    while {$k < 10} { incr k; if {$k % 2} continue; lappend s w$k }
    return $s
}
puts [loops]
proc deep {} { return -level 2 -code break x }
proc mid {} { foreach i {1 2 3} { deep; puts never } ; return after }
puts [catch {mid} m]
proc inloop {} { set s {}; foreach i {1 2 3} { lappend s [catch {return -code continue} m] $m }; return $s }
puts [inloop]
