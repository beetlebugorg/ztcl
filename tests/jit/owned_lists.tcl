# SPDX-License-Identifier: BSD-2-Clause
# A cell can own its list, and `lset` then writes in place. A value
# that another place holds must never change. Each case below keeps a
# copy of the list in one more place before or after an `lset`.

proc show {args} { puts $args }

# A copy in another variable, before and after the reads of lindex.
proc copy1 {} {
    set t [list 0 0 0 0]
    lset t 0 1
    set keep $t
    set x [lindex $t 0]
    lset t 1 2
    lset t 2 [expr {[lindex $t 1] + 1}]
    show $keep $t $x
}
copy1

# The read of llength and lindex between two writes keeps the owner.
proc reads {} {
    set t [list 0 0 0]
    lset t 0 1
    set n [llength $t]
    lset t 1 [expr {[lindex $t 0] + $n}]
    set k $t
    lset t 2 9
    show $t $k
}
reads

# The last command of a switch arm and of an if arm.
proc arms {op} {
    set t [list 0 0 0]
    set saved {}
    foreach o $op {
        switch -exact -- $o {
            INC { lset t 0 [expr {[lindex $t 0] + 1}] }
            KEEP { set saved $t }
            SET { if {1} { lset t 1 5 } else { lset t 1 6 } }
            TWO { lset t 2 7; lset t 2 8 }
        }
    }
    show $t $saved
}
arms {INC INC KEEP INC SET TWO}

# The result of an arm that the code reads.
proc used {} {
    set t [list a b]
    set r [switch -- x { x { lset t 0 z } }]
    lset t 1 y
    show $r $t
}
used

# An upvar alias, a global, and an array element.
proc inner {name} {
    upvar 1 $name v
    lset v 0 changed
}
proc alias {} {
    set t [list 1 2 3]
    lset t 2 three
    set copy $t
    inner t
    show $t $copy
}
alias
set ::g [list x y]
proc viaGlobal {} {
    global g
    set before $g
    lset g 0 X
    lset g 1 [lindex $g 0]
    show $before $g
}
viaGlobal
proc viaArray {} {
    set t [list 1 2]
    lset t 0 one
    set a(k) $t
    lset t 1 two
    show $a(k) $t
}
viaArray

# A dict that holds the list, and a list that holds it.
proc inContainers {} {
    set t [list 1 2]
    lset t 0 A
    set d [dict create k $t]
    set l [list $t]
    lset t 1 B
    show [dict get $d k] [lindex $l 0] $t
}
inContainers

# A variable trace sees each write, and the trace script keeps a copy.
proc tracer {args} { lappend ::seen [set ::tv] }
proc traced {} {
    set ::seen {}
    set ::tv [list 0 0]
    trace add variable ::tv write tracer
    global tv
    lset tv 0 1
    lset tv 1 [expr {[lindex $tv 0] + 1}]
    trace remove variable ::tv write tracer
    show $::seen $tv
}
traced

# A coroutine that yields the list between writes.
proc gen {} {
    set t [list 0 0 0]
    yield
    for {set i 0} {$i < 3} {incr i} {
        lset t $i [expr {[lindex $t $i] + $i + 1}]
        yield $t
    }
    return done
}
coroutine c gen
set got {}
for {set i 0} {$i < 4} {incr i} { lappend got [c] }
show $got

# The list that a proc returns and its caller keeps.
proc ret {t} {
    lset t 0 [expr {[lindex $t 0] + 1}]
    return $t
}
proc caller {} {
    set t [list 0 0]
    set a [ret $t]
    set b [ret $a]
    lset a 1 x
    show $t $a $b
}
caller

# The tape of bf.tcl: the caller holds the tape during the call.
proc run {tape pos} {
    lset tape $pos [expr {[lindex $tape $pos] + 1}]
    lset tape $pos [expr {[lindex $tape $pos] + 1}]
    return [list $tape $pos]
}
proc bf {} {
    set tape [list 0 0]
    set pos 0
    set hist {}
    for {set i 0} {$i < 3} {incr i} {
        set old $tape
        lassign [run $tape $pos] tape pos
        lappend hist $old
    }
    show $tape $hist
}
bf

# The fast call keeps the cells of a frame for the next call of the same
# Code. Recursion, other procs at the same depth, upvar, info locals,
# defaults, args, and a new body all start with fresh cells.
proc rec {n} {
    set local $n
    if {$n > 0} { rec [expr {$n - 1}] }
    return $local
}
proc a1 {x} { set y [expr {$x * 2}]; return [info locals] }
proc a2 {x} { return [info exists y] }
show [rec 5] [a1 1] [a2 1] [a1 2] [a2 2]
proc setter {name} { upvar 1 $name v; set v set }
proc holder {} { setter w; set w }
show [holder] [holder]
proc linker {} { global gg; set gg 1; return [info exists gg] }
proc plain {} { return [info exists gg] }
show [linker] [plain] [linker] [plain]
proc d {a {b B}} { return "$a $b" }
proc v {a args} { return "$a [llength $args]" }
show [d 1] [d 1 2] [d 1] [v 1] [v 1 2 3] [v 1]
proc body {x} { return one$x }
set r [body 1]
proc body {x} { set z two; return $z$x }
show $r [body 2] [body 3]
proc arr {} { set q(1) a; return [array size q] }
proc sc {} { return [info exists q] }
show [arr] [sc] [arr] [sc]
proc wrong {a b} { return $a$b }
show [catch {wrong 1} m] $m [wrong 1 2]
proc tc {n} { if {$n == 0} { return end }; tailcall tc [expr {$n - 1}] }
show [tc 3] [tc 0]
proc cond {f} { if {$f} { set w 1 }; return [info exists w] }
show [cond 1] [cond 0] [cond 1] [cond 0]
proc q1 {x} { set y 1; return [info locals] }
proc q2 {x} { set z 1; return [info locals] }
show [q1 1] [q2 1] [q1 1] [q2 1]
# An `lset` with two or more indexes writes the inner lists in place.
# Each case reads an inner list into one more place, at each level, and
# then writes through the outer variable.
proc nest {} {
    set m {{1 2} {3 4} {5 6}}
    for {set i 0} {$i < 3} {incr i} { lset m $i 1 x$i }
    set r [lindex $m 1]
    lset m 1 0 y
    set d [dict get {a {7 8}} a]
    set m [list $d {9 9}]
    lset m 0 0 z
    list $m $r $d
}
show [nest] [nest]
proc deep {} {
    set m {{{1 2} {3 4}} {{5 6} {7 8}}}
    lset m 0 1 0 a
    set r [lindex $m 0]
    set g [lindex $r 1]
    lset m 0 1 1 b
    set c $m
    lset m 1 0 0 c
    set s "$m"
    lset m 1 0 1 d
    set h [lindex $m 1 0]
    lset m 1 0 0 e
    foreach row $m { lappend f $row }
    lset m 0 0 0 f
    lassign $m p q
    lset m 1 1 1 g
    list $m $r $g $c $s $h $f $p $q
}
show [deep] [deep]
proc rows {n} {
    set m {}
    for {set i 0} {$i < $n} {incr i} { lappend m [lrepeat $n 0] }
    set keep {}
    for {set k 0} {$k < 3} {incr k} {
        for {set i 0} {$i < $n} {incr i} {
            for {set j 0} {$j < $n} {incr j} { lset m $i $j [expr {$i * $j + $k}] }
            if {$i == $k} { lappend keep [lindex $m $i] }
        }
    }
    list $m $keep
}
show [rows 4]
proc dicts {} {
    set m [list {a 1 b 2} {a 3 b 4}]
    lset m 0 1 10
    set e [dict get [lindex $m 0] a]
    set r [lindex $m 0]
    lset m 0 3 20
    list $m $e $r [dict get $r b]
}
show [dicts] [dicts]
proc other {l} { lset l 0 0 q; return $l }
proc pass {} {
    set m {{1 2} {3 4}}
    lset m 0 0 a
    set o [other $m]
    lset m 0 1 b
    set o2 [other [lindex $m 1]]
    lset m 1 0 c
    list $m $o $o2
}
show [pass] [pass]
proc shared {} {
    set m {{1 2} {3 4}}
    lset m 0 0 a
    upvar 0 m al
    set x [lindex $al 0]
    lset al 0 1 b
    lset m 0 0 c
    list $m $x
}
show [shared] [shared]
