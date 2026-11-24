proc p {} {
  set r {}
  for {set i 0} {$i < 8} {incr i} {
    if {$i == 2} { unset x }
    if {$i == 3} { array set x {a 1} }
    if {$i == 5} { unset x; set x 7 }
    if {$i == 6} { trace add variable x read {apply {{a b c} {upvar 1 x v; set v 1000}}} }
    catch {set x [expr {$i + 1}]} m; lappend r $m
    catch {expr {$x + $i}} m; lappend r $m
    catch {incr x} m; lappend r $m
  }
  return $r
}
puts [p]; puts [p]
proc q {} { set d {}; for {set i 0} {$i < 5} {incr i} { dict set d k$i $i; dict incr d k0; lset d 1 z }; return $d }
puts [q]; puts [q]
proc sh {} { set a "10"; set b 010; set c 0x1; set r {}; for {set i 0} {$i < 3} {incr i} { lappend r [expr {$a + $i}] [expr {$b + $i}] [expr {$c < $i}] [expr {$a == "10"}]; append a 0 }; return [list $r $a $b $c] }
puts [sh]; puts [sh]
proc dbl {} { set x 1.5; set r {}; for {set i 0} {$i < 3} {incr i} { lappend r [expr {$x + $i}] [expr {$x < $i}] [expr {$i * 1.0}]; set x [expr {$x * 2}] }; if {$x} {lappend r t}; return $r }
puts [dbl]; puts [dbl]
proc bools {} { set r {}; foreach v {yes no true 0 1 2 off "" abc 0.0} { lappend r [catch {if {$v} {set z 1} else {set z 0}} m] $m [catch {expr {!$v}} m] $m }; return $r }
puts [bools]; puts [bools]
