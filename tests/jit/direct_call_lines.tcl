# SPDX-License-Identifier: BSD-2-Clause
# The direct call of a compiled proc (jit/call.zig): -errorline, info
# level, and errorInfo of an error deep in a call chain. The lines of
# ztcl differ from tclsh in some cases, so this file has no .out file,
# and jit-diff.sh compares the modes of ztcl.

proc d0 {x} {
    set z [expr {$x + 1}]
    error "boom $z"
}
proc d1 {x} {
    set y 1
    d0 $x
}
proc fr {} {
    list [info level] [info level 0] [info level -1]
}
proc frcall {} {
    set a [fr]
    set b [fr]
    list $a $b
}
proc run {} {
    for {set i 0} {$i < 4} {incr i} {
        lappend out [catch {d1 $i} m o] $m [dict get $o -errorline] [dict get $o -level]
    }
    lappend out [frcall]
    return $out
}
puts [run]
puts $::errorInfo
