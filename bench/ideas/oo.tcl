# SPDX-License-Identifier: BSD-2-Clause
# Calls methods of two TclOO objects in a loop.
oo::class create Vec {
    variable x y
    constructor {ax ay} {set x $ax; set y $ay}
    method add {o} {set x [expr {$x + [$o x]}]; set y [expr {$y + [$o y]}]; return [self]}
    method x {} {return $x}
    method y {} {return $y}
    method norm2 {} {expr {$x*$x + $y*$y}}
}
proc run {n} {
    set a [Vec new 0 0]
    set b [Vec new 1 2]
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        $a add $b
        incr s [expr {[$a norm2] & 0xff}]
    }
    return $s
}
puts [run 200000]
