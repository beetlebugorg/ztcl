# SPDX-License-Identifier: BSD-2-Clause
# The direct call of a compiled proc from machine code (jit/call.zig):
# each case that leaves the direct path, and each state that the call
# changes and puts back.

proc add {a b} { expr {$a + $b} }
proc opt {a {b 10}} { expr {$a + $b} }
proc rest {a args} { llength $args }

# One site, called many times, then with a command that changes.
proc loop {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { set s [add $s $i] }
    return $s
}
puts [loop 100]
rename add add_old
proc add {a b} { expr {$a * 0 + $b} }
puts [loop 100]
rename add {}
rename add_old add
puts [loop 100]

# Too few and too many words, defaults, and args.
proc bad {k} {
    switch $k {
        0 { add 1 }
        1 { add 1 2 3 }
        2 { opt 1 }
        3 { rest 1 2 3 }
    }
}
foreach k {0 1 2 3} {
    puts [list $k [catch {bad $k} r] $r]
}

# A proc that redefines itself in its body.
proc self {} { proc self {} { return second }; return first }
proc callself {} { list [self] [self] }
puts [callself]

# The namespace of the body and of the caller.
namespace eval ns {
    proc where {} { namespace current }
    proc outer {} { list [where] [namespace current] }
}
proc where {} { return global }
proc top {} { list [where] [ns::outer] [where] }
puts [top]

# An execution trace on the command of a site.
proc traced {x} { incr x }
proc tloop {} {
    set out {}
    for {set i 0} {$i < 3} {incr i} {
        if {$i == 1} { trace add execution traced enter {apply {{c op} {puts "enter $c"}}} }
        lappend out [traced $i]
    }
    return $out
}
puts [tloop]

# Errors: errorInfo and the code of return. direct_call_lines.tcl has
# the cases with no output of tclsh.
proc d0 {x} {
    error boom
}
proc d1 {x} {
    set y 1
    d0 $x
}
proc deep {x} {
    d1 $x
}
proc rc {} { return -code 7 seven }
proc brk {} { break }
proc ecall {} {
    puts [list [catch {deep 3} m o] $m]
    puts $::errorInfo
    puts [list [catch {rc} m] $m]
    puts [list [catch {brk} m] $m]
}
ecall

# info level and uplevel in a body of a direct call.
proc lv {} { list [info level] [info level 0] [uplevel 1 {set v}] }
proc lvcall {} { set v here; lv }
puts [lvcall]

# tailcall to a compiled proc.
proc tgt {x} { expr {$x * 2} }
proc tc {x} { tailcall tgt $x }
proc tcloop {} { set s 0; for {set i 0} {$i < 5} {incr i} { incr s [tc $i] }; return $s }
puts [tcloop]

# The recursion limit.
proc rec {n} { rec [expr {$n + 1}] }
proc reccall {} { catch {rec 0} m; return $m }
puts [reccall]
puts [lindex [split $::errorInfo \n] 0]
