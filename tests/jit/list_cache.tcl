# SPDX-License-Identifier: BSD-2-Clause
# Differential test: each list reader of a string goes through the parse
# cache. The string form of a value stays its exact text, and a string
# with new bytes gets a new parse.
proc readers {n} {
    set l "a  b {c d}"
    set d {k 1 k 2 j {x y}}
    set r {}
    for {set i 0} {$i < $n} {incr i} {
        lappend r [llength $l] [lindex $l end] [lrange $l 0 1] [dict get $d k] [dict size $d]
        foreach x $l { lappend r $x }
        lappend r [lsearch $l b] [join $l ,] [lsort $l] [concat $l $l] [lreverse $l]
        switch -- [lindex $l 0] a { lappend r A } default { lappend r Z }
    }
    list $l $d [string length $l] $r
}
puts [readers 3]
proc fresh {n} {
    set r {}
    for {set i 0} {$i < $n} {incr i} {
        set s "x$i y z"
        lappend r [lindex $s 0] [llength "$s w"]
        set t [string repeat "q " $i]
        lappend r [llength $t]
    }
    return $r
}
puts [fresh 5]
proc script {} {
    set c {set v 7}
    set r [llength $c]
    eval $c
    lappend r $v [lindex $c 2] $c
}
puts [script]
proc bad {} {
    set s "a \{b"
    set r [list [catch {llength $s} m] $m [catch {lindex $s 0} m] $m]
    set s "a {b}"
    lappend r [llength $s]
}
puts [bad]
proc build {} {
    set r {}
    foreach w {{1 2 3} {4 5 6} {7 8 9}} {
        set s ""
        append s $w
        lappend r [lindex $s 1] [llength $s]
    }
    return $r
}
puts [build]
