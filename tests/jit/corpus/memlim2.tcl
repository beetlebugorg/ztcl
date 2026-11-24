proc grow {} { set l {}; set i 0; while 1 { lappend l [list $i $i $i]; incr i } }
grow
