# The checks of the encodings and the regular expressions: tests/cext/cxenc.c.
catch {load $dir/cxenc.so} msg
foreach pair $msg { puts [lindex $pair 0]:[lindex $pair 1] }
