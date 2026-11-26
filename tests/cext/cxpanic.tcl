# Tcl_Panic with a panic proc: tests/cext/cxpanic.c. The proc ends the
# process, so the script writes no line before the load.
load $dir/cxpanic.so
puts after
