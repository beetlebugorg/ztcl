# The checks of the area lists and dicts: tests/cext/cxdict.c.
catch {load $dir/cxdict.so} msg
foreach pair $msg { puts [lindex $pair 0]:[lindex $pair 1] }
