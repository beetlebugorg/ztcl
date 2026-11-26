# The checks of the area objects: tests/cext/cxobj.c.
catch {load $dir/cxobj.so} msg
foreach pair $msg { puts [lindex $pair 0]:[lindex $pair 1] }
