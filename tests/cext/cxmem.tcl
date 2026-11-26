# The checks of the memory and package slots: tests/cext/cxmem.c.
puts [catch {load $dir/cxmem.so} msg]:$msg
puts [catch {package present cxmem} msg]:$msg
puts [catch {load $dir/cxmem.so Cxmem} msg]:$msg
puts [catch {load $dir/cxmem.so Nosuch} msg]:$msg
puts [catch {load $dir/nosuch.so} msg]:$msg
