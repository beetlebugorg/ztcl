# The thread::* commands with good and bad arguments.
# SPDX-License-Identifier: BSD-2-Clause

set main [thread::id]
testglob id-1 {thread::id} tid0x*
test id-2 {thread::id x} {!wrong # args: should be "thread::id"}
test package-1 {package present Thread} 2.8.11

# create, exists, names
set t [thread::create]
test create-1 {thread::exists $t} 1
test create-2 {expr {$t in [thread::names] && $main in [thread::names]}} 1
test create-3 {thread::create a b c} {!wrong # args: should be "thread::create ?-joinable? ?script?"}
test create-4 {thread::create -joinable -foo {}} {!wrong # args: should be "thread::create ?-joinable? ?script?"}
test create-5 {thread::send [thread::create {set x 5; thread::wait}] {set x}} 5
test exists-1 {thread::exists tid0x999} 0
test exists-2 {thread::exists bad} {!invalid thread handle "bad"}
test exists-3 {thread::exists} {!wrong # args: should be "thread::exists id"}
test names-1 {thread::names x} {!wrong # args: should be "thread::names"}

# send
test send-1 {thread::send $t {expr {6 * 7}}} 42
test send-2 {thread::send $t {error foo bar BAZ}} {!foo}
test send-3 {catch {thread::send $t {error foo bar BAZ}} m o; list $m [dict get $o -errorcode]} {foo BAZ}
test send-4 {catch {thread::send $t {error foo bar}}; set ::errorInfo} "bar\n    invoked from within\n\"thread::send \$t {error foo bar}\""
test send-5 {list [thread::send $t {expr 1+1} v] $v} {0 2}
test send-6 {list [thread::send $t {error x} v] $v} {1 x}
test send-7 {list [catch {thread::send $t {return -code break}} m] $m} {2 {}}
test send-7b {list [catch {thread::send $t {return -code 5 x}} m] $m} {2 x}
test send-8 {thread::send} {!wrong # args: should be "thread::send ?-async? ?-head? id script ?varName?"}
test send-9 {thread::send tid0x999 {}} {!thread "tid0x999" does not exist}
test send-10 {thread::send bad {}} {!invalid thread handle "bad"}
test send-11 {thread::send $main {expr 2+3}} 5
test send-12 {thread::send $t {list [expr 1] [expr 2.5] {a b}}} {1 2.5 {a b}}
test send-13 {thread::send $t {set y 1}; thread::send $t {incr y}} 2

# a send in both directions: the main thread runs the send of the thread
# while it waits for its own reply.
set ::back 0
test both-1 {thread::send $t [list thread::send $main {incr ::back; expr {10 + $::back}}]} 11
test both-2 {set ::back} 1
set t2 [thread::create]
test both-3 {thread::send $t [list thread::send $t2 [list thread::send $main {expr 99}]]} 99

# async and the event loop
set ::r {}
thread::send -async $t {expr 3*3} ::r
test async-1 {vwait ::r; set ::r} 9
test async-2 {thread::send -async $t {set z 1}} {}
test async-3 {thread::send $t {set z}} 1

# -head: the script at the head of the queue runs first
thread::send $t {set ::log {}}
thread::send -async $t {after 200}
thread::send -async $t {lappend ::log a}
thread::send -async -head $t {lappend ::log b}
test head-1 {thread::send $t {set ::log}} {b a}

# broadcast
test broadcast-1 {thread::broadcast {set ::bc 1}; list [thread::send $t {set ::bc}] [thread::send $t2 {set ::bc}]} {1 1}
test broadcast-2 {thread::broadcast} {!wrong # args: should be "thread::broadcast script"}

# configure
test configure-1 {thread::configure $t} {-eventmark 0 -unwindonerror 0 -errorstate 0}
test configure-2 {thread::configure $t -eventmark 2; thread::configure $t -eventmark} 2
test configure-3 {thread::configure $t -foo} {!bad option "-foo", should be one of -eventmark, -unwindonerror or -errorstate}
test configure-4 {thread::configure $t -eventmark x} {!expected integer but got "x"}
test configure-5 {thread::configure $t -unwindonerror x} {!expected boolean value but got "x"}
test configure-6 {thread::configure $t -eventmark 1 -unwindonerror} {!wrong # args: should be "thread::configure threadlId ?optionName? ?value? ?optionName value?..."}
test configure-7 {thread::configure} {!wrong # args: should be "thread::configure threadlId ?optionName? ?value? ?optionName value?..."}

# -eventmark: an async send waits while the queue has 2 messages
thread::send $t {set ::n 0}
for {set i 0} {$i < 10} {incr i} {thread::send -async $t {after 5; incr ::n}}
test eventmark-1 {thread::send $t {set ::n}} 10
thread::configure $t -eventmark 0

# -unwindonerror: a send with an error ends the thread
set t3 [thread::create]
thread::configure $t3 -unwindonerror 1
catch {thread::send $t3 {error stop}}
test unwind-1 {waitfor {expr {![thread::exists $t3]}}} 1

# preserve and release
set t4 [thread::create]
test preserve-1 {thread::preserve $t4} 1
test preserve-2 {thread::release $t4} 0
test preserve-3 {waitfor {expr {![thread::exists $t4]}}} 1
test preserve-4 {thread::preserve a b} {!wrong # args: should be "thread::preserve ?threadId?"}
test release-1 {thread::release a b c} {!wrong # args: should be "thread::release ?-wait? ?threadId?"}
set t5 [thread::create]
test release-2 {thread::release -wait $t5; thread::exists $t5} 0
test release-3 {thread::send $t5 {}} "!thread \"$t5\" does not exist"
test unwind-2 {thread::unwind x} {!wrong # args: should be "thread::unwind"}
set t6 [thread::create {thread::unwind; thread::wait; set never 1}]
test unwind-3 {waitfor {expr {![thread::exists $t6]}}} 1

# join and exit
set j [thread::create -joinable {thread::exit 3}]
test join-1 {thread::join $j} 3
set j [thread::create -joinable {set x 1}]
after 100
test join-2 {thread::join $j} 0
test join-3 {thread::join $j} "!cannot join thread $j"
test join-4 {thread::join $t} "!cannot join thread $t"
test join-5 {thread::join} {!wrong # args: should be "thread::join id"}
set j [thread::create -joinable {catch {thread::exit 7}; set never 1}]
test exit-1 {thread::join $j} 7
test exit-2 {thread::exit} {!the main thread cannot exit with thread::exit}
test exit-3 {thread::exit a b} {!wrong # args: should be "thread::exit ?status?"}
test wait-1 {thread::wait x} {!wrong # args: should be "thread::wait"}

# cancel. The thread sets ::started in the main thread at %S in its
# script, so the cancel reaches the loop.
proc startloop {c script} {
    set ::started 0
    set sig "thread::send -async [thread::id] {set ::started 1}"
    thread::send -async $c [string map [list %S $sig] $script]
    vwait ::started
    after 20
}
set c [thread::create]
startloop $c {%S; while 1 {}}
thread::cancel $c
test cancel-1 {thread::send $c {expr 1}} 1
startloop $c {set r [catch {%S; while 1 {}} m]; set ::cm [list $r $m]}
thread::cancel $c custom
test cancel-2 {thread::send $c {set ::cm}} {1 custom}
startloop $c {catch {%S; while 1 {}}; set ::never 1}
thread::cancel -unwind $c
# -unwind also ends the thread::wait of the thread.
test cancel-3 {waitfor {expr {![thread::exists $c]}}} 1
test cancel-3b {thread::send $c {info exists ::never}} "!thread \"$c\" does not exist"
# A cancel of a thread between two scripts leaves its loop running.
set c [thread::create]
thread::cancel $c
after 50
test cancel-3c {thread::send $c {expr 2}} 2
test cancel-4 {thread::cancel $main} {!the main thread cannot be canceled}
test cancel-5 {thread::cancel} {!wrong # args: should be "thread::cancel ?-unwind? id ?result?"}
test cancel-6 {thread::cancel tid0x999} {!thread "tid0x999" does not exist}

# errorproc
proc ::onerr {id info} {set ::errs [list $id $info]}
test errorproc-1 {thread::errorproc ::onerr; thread::errorproc} ::onerr
thread::send -async $t {error async-bad}
vwait ::errs
test errorproc-2 {list [expr {[lindex $::errs 0] eq $t}] [lindex [split [lindex $::errs 1] \n] 0]} {1 async-bad}
set e [thread::create {error start-bad}]
vwait ::errs
test errorproc-3 {list [expr {[lindex $::errs 0] eq $e}] [lindex [split [lindex $::errs 1] \n] 0]} {1 start-bad}
test errorproc-4 {thread::errorproc a b} {!wrong # args: should be "thread::errorproc ?proc?"}

foreach x [thread::names] {if {$x ne $main} {thread::release $x}}
done
