proc p {} { catch {upvar 0 a b} m1; catch {upvar 0 b a} m2; puts "$m1|$m2"; for {set i 0} {$i < 3} {incr i} { catch {set a $i} m; puts $m } }
p; p
