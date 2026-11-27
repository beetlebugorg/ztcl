# SPDX-License-Identifier: BSD-2-Clause
# Differential test: a text that `subst` reads again gets its parts from
# the parse cache. The output of each read is the same as the first.
proc same {n} {
    set r {}
    set a(1) one
    for {set i 0} {$i < $n} {incr i} {
        lappend r [subst {v=$i [expr {$i+1}] \t$a([expr {1}]) \x41}]
        lappend r [subst -nobackslashes {v=$i \t[incr i 0]}]
        lappend r [subst -nocommands {v=$i [x] \n}]
        lappend r [subst -novariables {v=$i [string length ab] $}]
        lappend r [subst {a[break]b$i}] [subst {a[continue]b[set i]c}]
        lappend r [subst {a[return -level 0 R]b}] [subst {x[list 1 2; set q 3]y}]
        lappend r [subst {$ \$ [] $a(1)}] [subst {}]
    }
    return $r
}
puts [same 3]
proc bad {n} {
    set r {}
    for {set i 0} {$i < $n} {incr i} {
        lappend r [catch {subst {a[lappend r ran]$}} m] $m
        lappend r [catch {subst {a[lappend r ran2] [incr}} m] $m
        lappend r [catch {subst {a$nosuch}} m] $m
        lappend r [catch {subst {a[error boom]}} m] $m
    }
    return $r
}
puts [bad 3]
proc texts {n} {
    set r {}
    for {set i 0} {$i < $n} {incr i} {
        set t "k$i=\$i"
        lappend r [subst $t] [subst $t] [subst "$t \[set i\]"]
    }
    return $r
}
puts [texts 4]
proc trace_count {} {
    set n 0
    set v 5
    trace add variable v read [list apply {{args} {upvar 1 n n; incr n}}]
    for {set i 0} {$i < 3} {incr i} { subst {$v $v} }
    return $n
}
puts [trace_count]
