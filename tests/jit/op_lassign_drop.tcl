# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the instruction lassign_drop.
proc f {l} { lassign $l a b c; return [list $a $b $c] }
puts [f {x y}]
puts [f {1 2 3 4}]
# The inline path of tier 1: a list value, plain cells, and each case
# that goes to the helper.
proc g {l} {
    set a 0; set b 0
    lassign $l a b
    return [list $a $b]
}
puts [list [g [list 1 2]] [g [list 1]] [g [list]] [g [list 1 2 3]] [g "p q"] [g 5]]
proc same {l} { set a 0; lassign $l a a; return $a }
puts [same [list x y]]
proc linked {l} {
    upvar 1 out o
    set o 0
    set b 0
    lassign $l o b
    return $b
}
set out none
puts [list [linked [list 7 8]] $out]
proc fresh {l} { lassign $l n m; return "$n $m" }
puts [list [fresh [list 1 2]] [fresh [list 3]]]
proc arr {l} { set a(1) 0; catch {lassign $l a} msg; return $msg }
puts [arr [list 1]]
proc loop {} {
    set r {}
    foreach pair [list [list a 1] [list b 2] [list c]] {
        set k 0; set v 0
        lassign $pair k v
        lappend r $k $v
    }
    return $r
}
puts [loop]
