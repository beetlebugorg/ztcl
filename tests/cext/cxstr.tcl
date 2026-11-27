# The checks of the area strings: tests/cext/cxstr.c.
catch {load $dir/cxstr.so} msg
foreach pair $msg { puts [lindex $pair 0]:[lindex $pair 1] }
