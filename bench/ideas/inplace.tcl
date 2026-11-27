# SPDX-License-Identifier: BSD-2-Clause
# Times writes to a dict or a list in a proc with reads between the writes. Needs --allow clock.
proc t {name body} {
    set t0 [clock microseconds]
    uplevel #0 $body
    puts [format "%-22s %8.1f ms" $name [expr {([clock microseconds]-$t0)/1000.0}]]
}
proc mkd {n} {set d {}; for {set i 0} {$i<$n} {incr i} {dict set d k$i $i}; return $d}
proc d_setonly {d n} {for {set i 0} {$i<$n} {incr i} {dict set d k[expr {$i%1000}] $i}; return [dict size $d]}
proc d_setget {d n} {set s 0; for {set i 0} {$i<$n} {incr i} {set k k[expr {$i%1000}]; dict set d $k $i; incr s [dict get $d $k]}; return $s}
proc d_setexists {d n} {set s 0; for {set i 0} {$i<$n} {incr i} {set k k[expr {$i%1000}]; if {[dict exists $d $k]} {dict set d $k $i}}; return $s}
proc d_incrget {d n} {set s 0; for {set i 0} {$i<$n} {incr i} {set k k[expr {$i%1000}]; dict incr d $k; incr s [dict size $d]}; return $s}
proc d_lappend {n} {set d {}; for {set i 0} {$i<$n} {incr i} {dict lappend d k[expr {$i%100}] $i}; return [dict size $d]}
proc l_setget {n} {set l [lrepeat 1000 0]; set s 0; for {set i 0} {$i<$n} {incr i} {set k [expr {$i%1000}]; lset l $k $i; incr s [lindex $l $k]}; return $s}
proc l_setlen {n} {set l [lrepeat 1000 0]; set s 0; for {set i 0} {$i<$n} {incr i} {set k [expr {$i%1000}]; lset l $k $i; incr s [llength $l]}; return $s}
proc l_setpass {n} {set l [lrepeat 1000 0]; set s 0; for {set i 0} {$i<$n} {incr i} {set k [expr {$i%1000}]; lset l $k $i; incr s [peek $l $k]}; return $s}
proc peek {l k} {lindex $l $k}
proc l_setforeach {n} {set l [lrepeat 100 0]; set s 0; for {set i 0} {$i<$n} {incr i} {lset l [expr {$i%100}] $i; foreach x $l {incr s $x; break}}; return $s}
proc a_append {n} {for {set i 0} {$i<$n} {incr i} {lappend a([expr {$i%100}]) $i}; return [array size a]}
proc s_appendarr {n} {for {set i 0} {$i<$n} {incr i} {append a([expr {$i%100}]) x}; return [array size a]}
set D [mkd 1000]
t d_setonly {d_setonly $D 50000}
t d_setget {d_setget $D 50000}
t d_setexists {d_setexists $D 50000}
t d_incrget {d_incrget $D 50000}
t d_lappend {d_lappend 50000}
t l_setget {l_setget 50000}
t l_setlen {l_setlen 50000}
t l_setpass {l_setpass 50000}
t l_setforeach {l_setforeach 50000}
t a_append {a_append 50000}
t s_appendarr {s_appendarr 50000}
