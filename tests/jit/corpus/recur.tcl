proc r {n} { set ::d $n; for {set i 0} {$i < 1} {incr i} {}; r [expr {$n + 1}] }
catch {r 0} m; puts "$m $::d"
