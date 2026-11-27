# SPDX-License-Identifier: BSD-2-Clause
# Times 38 small procs, one idiom each. Needs --allow clock. count.sh runs one proc of this file.
proc t {name body} {
    set t0 [clock microseconds]
    uplevel #0 $body
    puts [format "%-18s %8.1f" $name [expr {([clock microseconds]-$t0)/1000.0}]]
}
set N 200000
proc m_exprcplx {n} {set s 0; for {set i 0} {$i<$n} {incr i} {set s [expr {($s + $i*3 - ($i>>2)) & 0xffff ^ ($i % 7 == 0 ? 1 : 2)}]}; return $s}
proc m_exprfn {n} {set s 0.0; for {set i 0} {$i<$n} {incr i} {set s [expr {$s + sqrt($i) + abs($i-5) + double($i)/3 + min($i,7)}]}; return $s}
proc m_strcmp {n} {set s 0; set a hello; for {set i 0} {$i<$n} {incr i} {if {$a eq "hello" && [string compare $a world] < 0 && [string equal -nocase $a HELLO]} {incr s}}; return $s}
proc m_strops {n} {set s 0; for {set i 0} {$i<$n} {incr i} {set x "item-$i"; incr s [string length [string toupper [string range $x 2 end]]]; incr s [string first - $x]}; return $s}
proc m_format {n} {set s 0; for {set i 0} {$i<$n} {incr i} {incr s [string length [format "%d:%s:%5.2f" $i abc 1.5]]}; return $s}
proc m_lindex2 {n} {set l {{1 2 3} {4 5 6} {7 8 9}}; set s 0; for {set i 0} {$i<$n} {incr i} {incr s [lindex $l [expr {$i%3}] 1]}; return $s}
proc m_lrange {n} {set l {}; for {set i 0} {$i<100} {incr i} {lappend l $i}; set s 0; for {set i 0} {$i<$n} {incr i} {incr s [llength [lrange $l 1 end]]}; return $s}
proc m_lreplace {n} {set l {}; for {set i 0} {$i<100} {incr i} {lappend l $i}; for {set i 0} {$i<$n} {incr i} {set l [lreplace $l 5 5 $i]}; return [llength $l]}
proc m_linsert {n} {set l {}; for {set i 0} {$i<$n} {incr i} {set l [linsert $l 0 $i]; if {[llength $l] > 50} {set l [lrange $l 0 9]}}; return [llength $l]}
proc m_lsetnest {n} {set m {}; for {set i 0} {$i<50} {incr i} {lappend m [lrepeat 50 0]}; for {set i 0} {$i<$n} {incr i} {lset m [expr {$i%50}] [expr {$i%47}] $i}; return [lindex $m 3 3]}
proc m_join {n} {set l [lrepeat 20 abc]; set s 0; for {set i 0} {$i<$n} {incr i} {incr s [string length [join $l ,]]}; return $s}
proc m_split {n} {set x "a,b,c,d,e,f,g,h"; set s 0; for {set i 0} {$i<$n} {incr i} {incr s [llength [split $x ,]]}; return $s}
proc m_dictnest {n} {set d {}; for {set i 0} {$i<$n} {incr i} {dict set d [expr {$i%100}] [expr {$i%10}] $i}; return [dict size $d]}
proc m_dictfor {n} {set d {}; for {set i 0} {$i<1000} {incr i} {dict set d k$i $i}; set s 0; for {set j 0} {$j<$n/1000} {incr j} {dict for {k v} $d {incr s $v}}; return $s}
proc m_dictlit {n} {set d {name bob age 42 city paris zip 75001}; set s 0; for {set i 0} {$i<$n} {incr i} {incr s [dict get $d age]; incr s [string length [dict get $d city]]}; return $s}
proc m_array {n} {for {set i 0} {$i<$n} {incr i} {set a(k[expr {$i%1000}]) $i}; set s 0; foreach k [array names a] {incr s $a($k)}; return $s}
proc m_arrayexists {n} {set s 0; for {set i 0} {$i<$n} {incr i} {if {![info exists a($i)]} {set a($i) 1; incr s}}; return $s}
proc m_global {n} {global G; set G 0; for {set i 0} {$i<$n} {incr i} {incr G $i}; return $G}
proc m_nsvar {n} {for {set i 0} {$i<$n} {incr i} {incr ::cnt::v $i}; return $::cnt::v}
namespace eval cnt {variable v 0}
proc m_upvar {n} {set x 0; for {set i 0} {$i<$n} {incr i} {bump x}; return $x}
proc bump {v} {upvar 1 $v x; incr x}
proc m_args {n} {set s 0; for {set i 0} {$i<$n} {incr i} {incr s [va $i 2 3]}; return $s}
proc va {a args} {expr {$a + [llength $args]}}
proc m_default {n} {set s 0; for {set i 0} {$i<$n} {incr i} {incr s [df $i]}; return $s}
proc df {a {b 5}} {expr {$a + $b}}
proc m_catch {n} {set s 0; for {set i 0} {$i<$n} {incr i} {if {[catch {expr {$i / ($i % 2)}} r]} {incr s}}; return $s}
proc m_try {n} {set s 0; for {set i 0} {$i<$n} {incr i} {try {incr s [expr {$i % 3}]} on error {e} {incr s -1} finally {incr s}}; return $s}
proc m_switch {n} {set s 0; for {set i 0} {$i<$n} {incr i} {switch -glob -- "k[expr {$i%5}]" {k0 {incr s} k1* {incr s 2} *3 {incr s 3} default {incr s 4}}}; return $s}
proc m_while {n} {set i 0; set s 0; while {$i < $n} {if {$i & 1} {incr s $i} else {incr s -1}; incr i}; return $s}
proc m_strappendl {n} {set s ""; for {set i 0} {$i<$n} {incr i} {set s "$s$i,"; if {[string length $s] > 200} {set s ""}}; return [string length $s]}
proc m_scan {n} {set s 0; for {set i 0} {$i<$n} {incr i} {scan "$i 42" "%d %d" a b; incr s $b}; return $s}
proc m_strmatch {n} {set s 0; for {set i 0} {$i<$n} {incr i} {if {[string match "*5*" $i]} {incr s}; if {[string is integer -strict $i]} {incr s}}; return $s}
proc m_info {n} {set s 0; for {set i 0} {$i<$n} {incr i} {if {[info exists s]} {incr s}; incr s [llength [info level 0]]}; return $s}
proc m_concat {n} {set s 0; for {set i 0} {$i<$n} {incr i} {set l [concat {a b} [list $i c] {d}]; incr s [llength $l]}; return $s}
proc m_lmapexp {n} {set l [lrepeat 100 3]; set s 0; for {set i 0} {$i<$n/100} {incr i} {incr s [tcl::mathop::+ {*}$l]}; return $s}
proc m_incrstr {n} {set l [split [string repeat "7 " 1000]]; set s 0; for {set j 0} {$j<$n/1000} {incr j} {foreach x $l {if {$x ne ""} {incr s $x}}}; return $s}
proc m_dblstr {n} {set l [split [string repeat "7.5 " 1000]]; set s 0; for {set j 0} {$j<$n/1000} {incr j} {foreach x $l {if {$x ne ""} {set s [expr {$s + $x}]}}}; return $s}
proc m_subst {n} {set s 0; for {set i 0} {$i<$n} {incr i} {incr s [string length [subst {v=$i [expr {$i+1}]}]]}; return $s}
proc m_strrev {n} {set s 0; for {set i 0} {$i<$n} {incr i} {incr s [string length [string trimleft [string reverse "  ab$i"]]]}; return $s}
proc m_binfmt {n} {set s 0; for {set i 0} {$i<$n} {incr i} {binary scan [binary format iS $i 7] iS a b; incr s $b}; return $s}
proc m_coro {n} {coroutine gen apply {{n} {yield; for {set i 0} {$i<$n} {incr i} {yield $i}; return -1}} $n; set s 0; while {[set v [gen]] >= 0} {incr s $v}; return $s}
set PL [lsort [info procs m_*]]
foreach p $PL {t $p [list $p $N]}
