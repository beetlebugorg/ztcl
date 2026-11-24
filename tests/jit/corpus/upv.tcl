proc inner {name} { upvar 1 $name v; for {set i 0} {$i < 5} {incr i} { incr v; append v2 x }; return $v }
proc outer {} { set a 1; inner a; inner a; puts $a; uplevel 0 {incr a 100}; puts $a; set b(1) 2; upvar 0 b(1) e; incr e; puts $b(1); for {set i 0} {$i < 3} {incr i} { uplevel 1 {incr ::g} ; upvar #0 g gg; incr gg } }
set g 0; outer; outer; puts $g
proc us {} { set x 5; for {set i 0} {$i < 4} {incr i} { if {$i==2} {unset x}; catch {incr x} m; puts "$i $m" } }
us; us
