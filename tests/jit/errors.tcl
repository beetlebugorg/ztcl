# SPDX-License-Identifier: BSD-2-Clause
# Differential test: errors, errorInfo, errorCode, and the error line.
proc inner {x} {
    set y [expr {$x * 2}]
    if {$y > 4} { error "too big: $y" "" {APP BIG} }
    return $y
}
proc outer {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        incr s [inner $i]
    }
    return $s
}
puts [catch {outer 5} m]
puts $m
puts $::errorInfo
puts $::errorCode
proc bad {} { set x 1; set y [expr {$x + $undefined}] }
puts [catch {bad} m]
puts $m
puts $::errorInfo
proc div {} { set a 1; set b 0; return [expr {$a / $b}] }
puts [catch {div} m]
puts $m
puts $::errorCode
