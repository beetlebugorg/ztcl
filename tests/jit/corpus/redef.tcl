proc t {} {
  set s 0
  for {set i 0} {$i < 6} {incr i} {
    if {$i == 2} { rename ::set ::_set; proc ::set {args} { puts "myset $args"; uplevel 1 [list ::_set {*}$args] } }
    if {$i == 4} { rename ::set {}; rename ::_set ::set }
    set s [expr {$s + $i}]
    if {$i == 3} { proc ::incr {v {n 1}} { upvar 1 $v x; ::set x [expr {$x + 10*$n}] } }
  }
  puts $s; puts $i
}
t; rename incr {}; catch t m; puts $m
