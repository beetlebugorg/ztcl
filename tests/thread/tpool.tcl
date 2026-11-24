# The thread pools.
# SPDX-License-Identifier: BSD-2-Clause

set p [tpool::create -minworkers 1 -maxworkers 4 -initcmd {proc sq {x} {expr {$x * $x}}}]
testglob create-1 {set p} tpool*
test create-2 {tpool::create -bogus 1} {!wrong # args: should be "tpool::create ?-minworkers count? ?-maxworkers count? ?-initcmd script? ?-exitcmd script? ?-idletime seconds?"}
test create-3 {tpool::create -minworkers x} {!expected integer but got "x"}
test names-1 {expr {$p in [tpool::names]}} 1
set j [tpool::post $p {sq 7}]
test post-1 {tpool::wait $p $j; tpool::get $p $j} 49
test post-2 {tpool::get $p $j} {!no such job}
test post-3 {tpool::post nope {expr 1}} {!can not find threadpool "nope"}
test post-4 {tpool::post $p} {!wrong # args: should be "tpool::post ?-detached? ?-nowait? tpoolId script"}
set jobs {}
for {set i 0} {$i < 20} {incr i} {lappend jobs [tpool::post $p [list sq $i]]}
set sum 0
set left $jobs
while {[llength $left]} {
    foreach d [tpool::wait $p $left left] {incr sum [tpool::get $p $d]}
}
test wait-1 {set sum} 2470
set e [tpool::post $p {error boom}]
test error-1 {tpool::wait $p $e; tpool::get $p $e} !boom
set e [tpool::post $p {error boom bar CODE}]
test error-2 {tpool::wait $p $e; catch {tpool::get $p $e} m o; list $m [dict get $o -errorcode]} {boom CODE}
test suspend-1 {tpool::suspend $p} {}
set s [tpool::post -nowait $p {sq 3}]
after 100
test cancel-1 {expr {[tpool::cancel $p $s] eq $s}} 1
test cancel-2 {tpool::get $p $s} {!no such job}
test resume-1 {tpool::resume $p} {}
test detached-1 {tpool::post -detached $p {sq 2}} {}
test preserve-1 {tpool::preserve $p} 1
test release-1 {tpool::release $p} 0
set q [tpool::create -maxworkers 2 -idletime 1 -exitcmd {tsv::incr tp exits}]
tsv::set tp exits 0
set qj {}
for {set i 0} {$i < 4} {incr i} {lappend qj [tpool::post $q {after 50; expr 1}]}
foreach x $qj {tpool::wait $q $x}
after 2500
test idle-1 {tsv::get tp exits} 2
test release-2 {tpool::release $q} 0
test release-3 {expr {$q in [tpool::names]}} 0
test wrong-1 {tpool::wait} {!wrong # args: should be "tpool::wait tpoolId jobIdList ?listVar"}
test wrong-2 {tpool::get $p} {!wrong # args: should be "tpool::get tpoolId jobId ?result?"}
test wrong-3 {tpool::cancel $p} {!wrong # args: should be "tpool::cancel tpoolId jobIdList ?listVar"}
test wrong-4 {tpool::suspend} {!wrong # args: should be "tpool::suspend tpoolId"}
test wrong-5 {tpool::bogus} {!invalid command name "tpool::bogus"}
# An error of -initcmd is the error of the create.
test init-1 {tpool::create -minworkers 1 -initcmd {error bad-init}} {!bad-init}

# A post when max_threads is full. With a worker, the job waits for it.
# With no worker, the post fails.
set q2 [tpool::create -maxworkers 3]
set j1 [tpool::post $q2 {expr 1}]
tpool::wait $q2 $j1
tpool::get $q2 $j1
set full {}
while {![catch {thread::create} t]} {lappend full $t}
testglob full-0 {set t} {too many threads*}
test full-1 {set j [tpool::post $q2 {after 50; expr 2}]; tpool::wait $q2 $j; tpool::get $q2 $j} 2
set q3 [tpool::create]
testglob full-2 {tpool::post $q3 {expr 3}} {!too many threads*}
foreach t $full {thread::release $t}
tpool::release $q2
tpool::release $q3

# A wait on a suspended pool with no running job gives an error.
set q4 [tpool::create -minworkers 1]
tpool::suspend $q4
set j4 [tpool::post $q4 {expr 4}]
test suspended-1 {tpool::wait $q4 $j4} {!the jobs of a suspended pool cannot end}
tpool::resume $q4
test suspended-2 {tpool::wait $q4 $j4; tpool::get $q4 $j4} 4
tpool::release $q4

# A pool worker is absent from thread::names.
set q5 [tpool::create -minworkers 2]
test names-2 {llength [thread::names]} 1
tpool::release $q5
done
