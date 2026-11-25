# tpool with 8 workers and 100 000 small jobs, in batches of 1000.
# Prints the time in milliseconds.
# SPDX-License-Identifier: BSD-2-Clause
package require Thread
set p [tpool::create -minworkers 8 -maxworkers 8 -initcmd {proc job {x} {expr {$x * 2}}}]
set t0 [clock milliseconds]
set sum 0
for {set b 0} {$b < 100} {incr b} {
    set jobs {}
    for {set i 0} {$i < 1000} {incr i} {lappend jobs [tpool::post $p [list job $i]]}
    while {[llength $jobs]} {
        foreach j [tpool::wait $p $jobs jobs] {incr sum [tpool::get $p $j]}
    }
}
puts "tpool [expr {[clock milliseconds] - $t0}] $sum"
tpool::release $p
