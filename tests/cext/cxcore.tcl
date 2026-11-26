# The checks of the shared core of objects and results: tests/cext/cxcore.c.
puts [catch {load $dir/cxcore.so} msg]:$msg
puts [llength $msg]:[lindex $msg 3]
