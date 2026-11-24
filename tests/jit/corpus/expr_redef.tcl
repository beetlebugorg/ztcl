proc t {} { set r {}; for {set i 0} {$i < 4} {incr i} { lappend r [expr {$i * 2}] [llength $r] [lindex $r end] [string length $r]; if {$i == 1} { proc ::tcl::mathop::* args { return 99 }; proc ::llength args {return L}; proc ::lindex args {return I} } }; return $r }
puts [t]
