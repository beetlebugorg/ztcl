# SPDX-License-Identifier: BSD-2-Clause
# Times dict set, lset, and lappend on global, namespace, array, and object variables. Needs --allow clock.
proc t {name body} {
    set t0 [clock microseconds]
    uplevel #0 $body
    puts [format "%-22s %8.1f ms" $name [expr {([clock microseconds]-$t0)/1000.0}]]
}
proc mkd {n} {set d {}; for {set i 0} {$i<$n} {incr i} {dict set d k$i $i}; return $d}
set D [mkd 1000]
set L [lrepeat 1000 0]
t top_dictset {for {set i 0} {$i<50000} {incr i} {dict set D k[expr {$i%1000}] $i}}
t top_lset {for {set i 0} {$i<50000} {incr i} {lset L [expr {$i%1000}] $i}}
t top_lappend {set Q {}; for {set i 0} {$i<50000} {incr i} {lappend Q $i}}
proc g_dictset {n} {global D; for {set i 0} {$i<$n} {incr i} {dict set D k[expr {$i%1000}] $i}}
proc g_lset {n} {global L; for {set i 0} {$i<$n} {incr i} {lset L [expr {$i%1000}] $i}}
proc ns_dictset {n} {for {set i 0} {$i<$n} {incr i} {dict set ::D k[expr {$i%1000}] $i}}
proc arr_dictset {n} {set a(x) $::D; for {set i 0} {$i<$n} {incr i} {dict set a(x) k[expr {$i%1000}] $i}}
proc arr_lset {n} {set a(x) $::L; for {set i 0} {$i<$n} {incr i} {lset a(x) [expr {$i%1000}] $i}}
proc arr_lappend {n} {for {set i 0} {$i<$n} {incr i} {lappend a(x) $i}}
oo::class create C {
    variable d l
    constructor {} {set d $::D; set l $::L}
    method ds {n} {for {set i 0} {$i<$n} {incr i} {dict set d k[expr {$i%1000}] $i}}
    method ls {n} {for {set i 0} {$i<$n} {incr i} {lset l [expr {$i%1000}] $i}}
    method la {n} {for {set i 0} {$i<$n} {incr i} {lappend l $i}}
}
set o [C new]
t g_dictset {g_dictset 50000}
t g_lset {g_lset 50000}
t ns_dictset {ns_dictset 50000}
t arr_dictset {arr_dictset 50000}
t arr_lset {arr_lset 50000}
t arr_lappend {arr_lappend 50000}
t oo_dictset {$o ds 50000}
t oo_lset {$o ls 50000}
t oo_lappend {$o la 50000}
