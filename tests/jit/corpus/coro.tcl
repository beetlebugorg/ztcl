proc gen {n} { yield [info coroutine]; for {set i 0} {$i < $n} {incr i} { set x [list a $i [string repeat b $i]]; yield $x }; return done }
coroutine g gen 50
set out {}
while 1 { set v [g]; lappend out [lindex $v 1]; if {$v eq "done"} break }
puts $out
proc k {} { set l {}; foreach x {1 2 3 4} { lappend l [yield $x] }; return $l }
coroutine c k
puts [c a]; puts [c b]; rename c {}
coroutine c2 k; c2 1; puts [info commands c2]
proc dd {} { coroutine c3 k; c3 x; rename c3 {}; return ok }
puts [dd]; puts [dd]
