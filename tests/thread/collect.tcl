# The collector runs in the loops of a thread: the wait loop with
# events, the scripts of messages, and the jobs of a pool worker. Each
# loop makes much more garbage than the memory limit of a thread.
# thread-tests-flags: --allow channels,socket --thread-mem 8388608
# SPDX-License-Identifier: BSD-2-Clause

set t [thread::create]
test events-1 {thread::send $t {
    proc accept {c a p} {}
    set srv [socket -server accept -myaddr 127.0.0.1 0]
    set s [socket 127.0.0.1 [lindex [fconfigure $srv -sockname] 2]]
    set n 0
    fileevent $s writable {if {[incr ::n] >= 15000} {set ::done 1}}
    vwait ::done
    close $s; close $srv
    set n
}} 15000
test sends-1 {for {set i 0} {$i < 150} {incr i} {thread::send $t {string length [string repeat x 100000]}}} {}
set p [tpool::create -maxworkers 1]
test jobs-1 {for {set i 0} {$i < 150} {incr i} {set j [tpool::post $p {string length [string repeat x 100000]}]; tpool::wait $p $j; tpool::get $p $j}} {}
tpool::release $p
thread::release -wait $t
done
