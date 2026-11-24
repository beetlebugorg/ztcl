# SPDX-License-Identifier: BSD-2-Clause
# Differential test: upvar, global, and variable in compiled code.
set gtotal 0
namespace eval cnt { variable n 0 }
proc add {name by} { upvar 1 $name v; incr v $by }
proc f {} {
    global gtotal
    variable ::cnt::n
    set local 0
    for {set i 0} {$i < 5} {incr i} {
        add local $i
        incr gtotal [expr {$local + 1}]
        set ::cnt::n [expr {$::cnt::n + 2}]
    }
    upvar 0 local alias
    incr alias 100
    return [list $local $gtotal $::cnt::n]
}
puts [f]
puts [f]
proc el {} { array set a {k 1}; upvar 0 a(k) e; for {set i 0} {$i < 3} {incr i} { incr e; set t [expr {$e * 2}] }; return [list $a(k) $t] }
puts [el]
