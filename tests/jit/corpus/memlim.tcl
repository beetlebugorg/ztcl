proc grow {} { set s x; set l {}; while 1 { append s $s; lappend l $s; set k [string length $s] } }
grow
