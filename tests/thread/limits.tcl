# The capability, max_threads, the memory limit of one thread, and cancel.
# thread-tests-flags: --allow interp --threads 8 --thread-compute 20000000 --thread-mem 67108864
# SPDX-License-Identifier: BSD-2-Clause

set main [thread::id]

# 1. The capability is absent in a safe child and in a child of a thread.
interp create -safe sc
test cap-1 {sc eval {info commands thread::*}} {}
test cap-2 {sc eval {info commands tsv::*}} {}
interp delete sc
interp create c1
test cap-3 {c1 eval {info commands thread::*}} {}
interp delete c1
set t [thread::create]
test cap-4 {thread::send $t {interp create c; c eval {info commands thread::*}}} {}
test cap-5 {thread::send $t {llength [info commands thread::*]}} [llength [info commands thread::*]]
thread::release -wait $t

# 2. max_threads: the next create fails, and the count comes back after
# a join.
set ts {}
for {set i 0} {$i < 8} {incr i} {lappend ts [thread::create -joinable]}
testglob max-1 {thread::create} {!too many threads: the limit is 8}
set last [lindex $ts end]
thread::send $last {thread::release}
thread::join $last
test max-2 {set x [thread::create]; thread::release -wait $x} 0
foreach x [lrange $ts 0 end-1] {thread::send -async $x {thread::release}; thread::join $x}

# 3. The memory limit of one thread stops only that thread. The error
# goes to thread::errorproc and to the joiner. steps.tcl tests the step
# limit.
proc ::onerr {id info} {lappend ::errs [list $id [lindex [split $info \n] 0]]}
thread::errorproc ::onerr
set ::errs {}
set m [thread::create -joinable {set s x; while 1 {append s $s}}]
test mem-1 {thread::join $m} 1
test mem-2 {waitfor {llength $::errs}; lindex $::errs 0} [list $m {the script used too much memory}]
test main-1 {expr {6 * 7}} 42

# 5. A thread passes its memory limit while 7 others run.
set ::errs {}
set run {}
for {set i 0} {$i < 7} {incr i} {
    lappend run [thread::create -joinable {
        set n 0
        while {![tsv::exists stop now]} {incr n; after 1}
        tsv::incr done n
    }]
}
set m [thread::create -joinable {set s x; while 1 {append s $s}}]
test mem7-1 {thread::join $m} 1
test mem7-2 {expr {[llength [thread::names]] >= 8}} 1
tsv::set stop now 1
foreach x $run {thread::join $x}
test mem7-3 {tsv::get done n} 7

# 6. thread::cancel of a thread in a bytecode loop, in a native loop, in
# vwait, in a mutex wait, and in a condition wait.
proc startloop {c script} {
    set ::started 0
    set sig "thread::send -async [thread::id] {set ::started 1}"
    thread::send -async $c [string map [list %S $sig] $script]
    vwait ::started
    after 20
}
set c [thread::create]
thread::send $c {set ::r {}}
set mx [thread::mutex create]
set cv [thread::cond create]
set cm [thread::mutex create]
thread::mutex lock $mx
foreach {name script} [list \
    bytecode {%S; while 1 {}} \
    native {%S; time {set x 1} 1000000000} \
    vwait {%S; vwait ::never} \
    mutex "%S; thread::mutex lock $mx" \
    cond "thread::mutex lock $cm; %S; thread::cond wait $cv $cm" \
] {
    startloop $c "set code \[catch {$script} msg\]; lappend ::r \[list $name \$code \$msg\]"
    thread::cancel $c
    test cancel-$name {waitfor {thread::send $c {llength $::r}}; thread::send $c {lindex $::r end}} [list $name 1 {eval canceled}]
    thread::send $c {set ::r {}}
}
thread::mutex unlock $mx
test cancel-cond-relock {thread::send $c [list thread::mutex unlock $cm]} {}
thread::release -wait $c
done
