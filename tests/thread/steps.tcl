# The step limit of one thread stops only that thread. The error goes to
# thread::errorproc and to the joiner. The limit is small: with
# --gc-stress 1 each step of the loop runs a collection.
# thread-tests-flags: --thread-steps 200000
# SPDX-License-Identifier: BSD-2-Clause

proc ::onerr {id info} {lappend ::errs [list $id [lindex [split $info \n] 0]]}
thread::errorproc ::onerr
set ::errs {}
set s [thread::create -joinable {while 1 {}}]
test steps-1 {thread::join $s} 1
test steps-2 {waitfor {llength $::errs}; lindex $::errs 0} [list $s {step limit reached}]
test steps-3 {expr {6 * 7}} 42
set t [thread::create -joinable {set n 0; while {$n < 1000} {incr n}; set n}]
test steps-4 {thread::join $t} 0
done
