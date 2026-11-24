proc loop {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i}] }; return $s }
proc w {} { set i 0; while 1 { incr i } }
puts [loop 100]
w
