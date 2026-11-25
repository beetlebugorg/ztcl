# A pipeline of 4 threads with 100 000 messages. Each stage adds 1 and
# sends the value to the next stage. The queue of each stage holds at
# most 1000 messages (-eventmark). Prints the time in milliseconds.
# SPDX-License-Identifier: BSD-2-Clause
package require Thread
set n 100000
set main [thread::id]
set stages {}
for {set s 0} {$s < 4} {incr s} {lappend stages [thread::create]}
for {set s 0} {$s < 4} {incr s} {
    set t [lindex $stages $s]
    thread::configure $t -eventmark 1000
    if {$s < 3} {
        thread::send $t [list proc fwd {v} "thread::send -async [lindex $stages [expr {$s + 1}]] \[list fwd \[expr {\$v + 1}\]\]"]
    } else {
        thread::send $t [list set ::main $main]
        thread::send $t [list set ::n $n]
        thread::send $t {
            set ::count 0
            set ::sum 0
            proc fwd {v} {
                incr ::sum $v
                if {[incr ::count] == $::n} {thread::send -async $::main [list set ::done $::sum]}
            }
        }
    }
}
set t0 [clock milliseconds]
set first [lindex $stages 0]
for {set i 0} {$i < $n} {incr i} {thread::send -async $first [list fwd $i]}
vwait ::done
puts "pipe [expr {[clock milliseconds] - $t0}] $::done"
foreach t $stages {thread::release $t}
