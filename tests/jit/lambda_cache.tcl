# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the proc cache of apply, and eval and uplevel of
# lists. A write in place to a lambda gives a new proc.
set lam {{a b} {expr {$a + $b}}}
set s 0
for {set i 0} {$i < 300} {incr i} { set s [apply $lam $s $i] }
puts $s
namespace eval ns { proc h {} {return ns} }
set l2 [list {x} {h} ns]
puts [apply $l2 1]
set l3 [list {x} {return $x}]
puts [apply $l3 5]
lset l3 1 {return [expr {$x*2}]}
puts [apply $l3 5]
puts [lsort -command {apply {{a b} {expr {$a - $b}}}} {5 3 9 1}]
catch {apply {{a a b} {}} 1} m; puts $m
catch {apply {{} {} nosuch} } m; puts $m
catch {apply {{x} {error bad}} 1} m; puts $::errorInfo
namespace delete ns
catch {apply $l2 1} m; puts $m
set d [dict create {x} {return $x}]
puts [apply $d 9]
dict set d {x} {return [list $x $x]}
puts [apply $d 9]
proc add {a b} {expr {$a + $b}}
proc f {} {
    set cmd [list add 1]
    set s 0
    for {set i 0} {$i < 100} {incr i} { set s [eval $cmd $i] }
    for {set i 0} {$i < 100} {incr i} { set s [eval $cmd [list $i]] }
    for {set i 0} {$i < 100} {incr i} { set s [uplevel 1 $cmd [list $i]] }
    for {set i 0} {$i < 100} {incr i} { set s [uplevel #0 [list add $s $i]] }
    for {set i 0} {$i < 100} {incr i} { set s [eval [list add] 1.5 $i] }
    catch {eval [list error boom] [list x]} m
    puts $m
    puts $::errorInfo
    catch {uplevel 1 [list error boom2] [list y]} m
    # After `error msg info`, tclsh keeps the line of an earlier error.
    puts [regsub {line [0-9]+\)} $::errorInfo {line N)}]
    proc g {} {uplevel 1 [list set zz 7]; uplevel 1 [list info level]}
    puts [g]
    return $s
}
puts [f]
