# jit-diff-flags: --tcl 9.1
# The commands and the number forms of Tcl 9.1 in procs and loops.
proc sum {n} {
    set t 0
    foreach x [lseq $n] { incr t $x }
    return $t
}
proc evens {l} { lfilter x $l {expr {$x % 2 == 0}} }
proc pops {l} {
    set out {}
    while {[llength $l]} { lappend out [lpop l] }
    return $out
}
proc octal {} {
    set r {}
    for {set i 0} {$i < 3} {incr i} { lappend r [expr {010 + $i}] [incr i 0] }
    return $r
}
proc edit {} {
    set l [lseq 1 10]
    for {set i 0} {$i < 5} {incr i} { ledit l $i $i [expr {$i * 100}] }
    lremove $l 0 end
}
proc names {} {
    set acc {}
    array set A {a 1 b 2 c 3}
    array for {k v} A { lappend acc $k[string insert $v 0 =] }
    dict getdef {a {b 2}} a b 0
    return $acc
}
proc math {} {
    set r {}
    foreach x {0.5 2 -3.7 27} {
        lappend r [expr {trunc($x) + log2(abs($x)) + cbrt($x) + signbit($x) + isnan($x)}]
    }
    lappend r [divmod -7 2] [frexp 10] [modf -2.5] [remquo 7 2] [fpclassify 1e-310]
    return $r
}
for {set k 0} {$k < 20} {incr k} {
    sum 100; evens [lseq 50]; pops {a b c d}; octal; edit; names; math
}
puts [sum 100]
puts [evens [lseq 20]]
puts [pops {a b c d}]
puts [octal]
puts [edit]
puts [names]
puts [math]
puts [lseq 0 1 0.1]
catch {encoding convertfrom utf-8 "a\xffb"} m; puts $m
namespace eval q { puts [catch {set tcl_version} m] }
