proc cnt {n acc} { if {$n == 0} { return $acc }; for {set i 0} {$i < 2} {incr i} { incr acc }; tailcall cnt [expr {$n - 1}] $acc }
puts [cnt 2000 0]
proc tl {} { foreach x {1 2 3} { if {$x == 2} { tailcall list tail $x } } }
puts [tl]
