# Runs one script with fresh counts of the collector and prints them as
# one line: GCSTATS {dict} WALL_NS. `run.tcl` starts it with --tclsh in a process of
# its own for each script. Needs --allow meter,file,clock,channels.
set script [lindex $argv 0]
ztcl::gc reset
set t0 [clock microseconds]
source $script
set wall [expr {([clock microseconds] - $t0) * 1000}]
puts "GCSTATS [list [ztcl::gc stats]] $wall"
