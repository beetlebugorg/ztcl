# SPDX-License-Identifier: BSD-2-Clause
# Times apply, a proc call, uplevel with a list, and lsort -command. Needs --allow clock.
proc t {name body} {
    set t0 [clock microseconds]
    uplevel #0 $body
    puts [format "%-22s %8.1f ms" $name [expr {([clock microseconds]-$t0)/1000.0}]]
}
proc a1 {n} {set lam {{a b} {expr {$a+$b}}}; set s 0; for {set i 0} {$i<$n} {incr i} {set s [apply $lam $s $i]}; return $s}
proc a2 {n} {set s 0; for {set i 0} {$i<$n} {incr i} {set s [apply {{a b} {expr {$a+$b}}} $s $i]}; return $s}
proc a3 {n} {set cmd [list apply {{a b} {expr {$a+$b}}}]; set s 0; for {set i 0} {$i<$n} {incr i} {set s [{*}$cmd $s $i]}; return $s}
proc add {a b} {expr {$a+$b}}
proc a4 {n} {set s 0; for {set i 0} {$i<$n} {incr i} {set s [add $s $i]}; return $s}
proc a5 {n} {set cmd add; set s 0; for {set i 0} {$i<$n} {incr i} {set s [uplevel #0 [list $cmd $s $i]]}; return $s}
proc a6 {n} {set l {}; for {set i 0} {$i<$n} {incr i} {lappend l [expr {($i*7919)%1000}]}; llength [lsort -command {apply {{a b} {expr {$a-$b}}}} $l]}
proc cmpi {a b} {expr {$a-$b}}
proc a7 {n} {set l {}; for {set i 0} {$i<$n} {incr i} {lappend l [expr {($i*7919)%1000}]}; llength [lsort -command cmpi $l]}
t apply-var {a1 200000}
t apply-lit {a2 200000}
t apply-expand {a3 200000}
t proc {a4 200000}
t uplevel-list {a5 200000}
t lsort-apply {a6 20000}
t lsort-proc {a7 20000}
