# Reads 1M integers and sorts them.
set f [open [file join [lindex $argv 0] ints.txt]]
set xs [split [string trim [read $f]] \n]
close $f
set s [lsort -integer $xs]
set n [llength $s]
puts "$n [lindex $s 0] [lindex $s [expr {$n / 2}]] [lindex $s end]"
