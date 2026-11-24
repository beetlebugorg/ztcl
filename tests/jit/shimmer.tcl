# SPDX-License-Identifier: BSD-2-Clause
# Differential test: values that change their form.
proc f {a b} {
    set r {}
    lappend r [expr {$a + $b}] [expr {$a < $b}] [string length $a]
    set l $a
    lappend l x
    lappend r [llength $a] [lindex $a 0]
    set c $a
    incr c
    lappend r $c [expr {$c * 2}]
    return $r
}
puts [f 10 20]
puts [f "  7 " 0x10]
puts [list [catch {f 3.5 2} m] $m]
puts [list [catch {f 1e2 1} m] $m]
puts [catch {f {a b} 1} m]
puts $m
proc g {} { set s 0012; set t [expr {$s + 1}]; return [list $s $t [expr {$s == 12}]] }
puts [g]
