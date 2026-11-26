# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `set name(index) value` on local, global, linked,
# traced, and scalar variables, in a proc and in named code.
proc f {} {
    set a(x) 1
    set a() 2
    set a(p$a(x)q) 3
    set k "z)(w"
    set a($k) 4
    set a(m[set k]) 5
    set r [set a(n) 9]
    foreach n [lsort [array names a]] { lappend o $n=$a($n) }
    set s 1
    lappend o [catch {set s(1) 2} e] $e
    upvar 0 a(x) ax
    lappend o [catch {set ax(2) 3} e] $e $r
    trace add variable t write {apply {args { lappend ::tr $args }}}
    set t(4) 5
    lappend o $::tr
    global g
    set g(1) 7
    lappend o $::g(1)
    for {set i 0} {$i < 5} {incr i} { set c($i) [expr {$i * $i}] }
    lappend o [lsort -stride 2 [array get c]]
    return $o
}
set tr {}
puts [f]
set i 3
set b($i) x
set b($i$i) y
puts [lsort -stride 2 [array get b]]
lappend err [catch {set i(1) 2} e] $e
puts $err
