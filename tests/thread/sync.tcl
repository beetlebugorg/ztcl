# The mutexes, the conditions, and thread::eval.
# SPDX-License-Identifier: BSD-2-Clause

set m [thread::mutex create]
testglob mutex-1 {set m} mid*
test mutex-2 {thread::mutex lock $m; thread::mutex unlock $m} {}
test mutex-3 {thread::mutex lock $m; set r [catch {thread::mutex lock $m} e]; thread::mutex unlock $m; list $r $e} {1 {locking the same exclusive mutex twice from the same thread}}
test mutex-5 {thread::mutex lock nope} {!no such mutex "nope"}
test mutex-6 {thread::mutex bogus $m} {!bad option "bogus": must be create, destroy, lock, or unlock}
test mutex-7 {thread::mutex} {!wrong # args: should be "thread::mutex option ?args?"}
test mutex-8 {thread::mutex lock} {!wrong # args: should be "thread::mutex lock mutexHandle"}
set r [thread::mutex create -recursive]
test rec-1 {thread::mutex lock $r; thread::mutex lock $r; thread::mutex unlock $r; thread::mutex unlock $r} {}
test rec-2 {thread::mutex create -bogus} {!wrong # args: should be "thread::mutex create ?-recursive?"}
test destroy-1 {thread::mutex lock $m; set x [catch {thread::mutex destroy $m} e]; thread::mutex unlock $m; list $x $e} {1 {mutex is in use}}
test destroy-2 {thread::mutex destroy $m} {}
test destroy-3 {thread::mutex destroy $m} {!no such mutex "mid0"}
set rw [thread::rwmutex create]
testglob rw-1 {set rw} wid*
test rw-2 {thread::rwmutex rlock $rw; thread::rwmutex rlock $rw; thread::rwmutex unlock $rw; thread::rwmutex unlock $rw} {}
test rw-3 {thread::rwmutex wlock $rw; set x [catch {thread::rwmutex wlock $rw} e]; thread::rwmutex unlock $rw; list $x $e} {1 {write-locking the same read-write mutex twice from the same thread}}
test rw-4 {thread::rwmutex wlock $rw; set x [catch {thread::rwmutex rlock $rw} e]; thread::rwmutex unlock $rw; list $x $e} {1 {read-locking already write-locked mutex from the same thread}}
test rw-6 {thread::rwmutex bogus $rw} {!bad option "bogus": must be create, destroy, rlock, wlock, or unlock}
test rw-7 {thread::rwmutex destroy $rw} {}
set c [thread::cond create]
testglob cond-1 {set c} cid*
set cm [thread::mutex create]
test cond-2 {thread::mutex lock $cm; set t0 [clock milliseconds]; thread::cond wait $c $cm 100; set d [expr {[clock milliseconds] - $t0}]; thread::mutex unlock $cm; expr {$d >= 90}} 1
test cond-3 {thread::cond wait $c $cm 10} {!mutex not locked or wrong type}
test cond-4 {thread::cond notify $c} {}
test cond-5 {thread::cond bogus $c} {!bad option "bogus": must be create, destroy, notify, or wait}
test cond-6 {thread::cond wait $c} {!wrong # args: should be "thread::cond wait condHandle mutexHandle ?timeout?"}
test cond-8 {thread::cond destroy $c} {}
test cond-9 {thread::cond notify $c} {!no such condition variable "cid3"}
test eval-1 {thread::eval {set z 1}} 1
test eval-2 {thread::eval set z 2} 2
set em [thread::mutex create]
test eval-3 {thread::eval -lock $em {expr 3}} 3
test eval-4 {thread::eval} {!wrong # args: should be "thread::eval ?-lock <mutexHandle>? arg ?arg...?"}
test eval-5 {thread::eval -lock nope {expr 3}} {!no such mutex "nope"}

# An exclusive mutex across threads: 4 threads add 500 each to a tsv
# element with a read and a write under the mutex.
set m [thread::mutex create]
tsv::set sx v 0
set ts {}
for {set i 0} {$i < 4} {incr i} {
    lappend ts [thread::create -joinable [list apply {{m} {
        for {set k 0} {$k < 500} {incr k} {
            thread::mutex lock $m
            set v [tsv::get sx v]
            tsv::set sx v [expr {$v + 1}]
            thread::mutex unlock $m
        }
    }} $m]]
}
foreach t $ts {thread::join $t}
test excl-1 {tsv::get sx v} 2000

# Readers share a read-write mutex. A writer waits for them.
set rw [thread::rwmutex create]
thread::rwmutex rlock $rw
set rd [thread::create -joinable [list apply {{rw} {
    thread::rwmutex rlock $rw
    tsv::set rws r 1
    thread::rwmutex unlock $rw
}} $rw]]
thread::join $rd
test rw-share-1 {tsv::get rws r} 1
set wr [thread::create -joinable [list apply {{rw} {
    thread::rwmutex wlock $rw
    tsv::set rws w [tsv::get rws order]
    thread::rwmutex unlock $rw
}} $rw]]
after 100
tsv::set rws order after-read
thread::rwmutex unlock $rw
thread::join $wr
test rw-writer-1 {tsv::get rws w} after-read

# A producer and a consumer with a condition.
set pm [thread::mutex create]
set pc [thread::cond create]
tsv::set pq items {}
set cons [thread::create -joinable [list apply {{pm pc} {
    set got {}
    thread::mutex lock $pm
    while {[llength $got] < 20} {
        while {[tsv::llength pq items] == 0} {thread::cond wait $pc $pm 1000}
        lappend got [tsv::lpop pq items]
    }
    thread::mutex unlock $pm
    tsv::set pq got $got
}} $pm $pc]]
for {set i 0} {$i < 20} {incr i} {
    thread::mutex lock $pm
    tsv::lappend pq items $i
    thread::cond notify $pc
    thread::mutex unlock $pm
}
thread::join $cons
test prodcons-1 {tsv::get pq got} {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19}

# A thread that ends with a mutex held frees it.
set hm [thread::mutex create]
set h [thread::create -joinable [list thread::mutex lock $hm]]
thread::join $h
test held-end-1 {thread::mutex lock $hm; thread::mutex unlock $hm} {}

# destroy of a mutex that another thread holds is an error.
set dm [thread::mutex create]
set d [thread::create "thread::mutex lock $dm; thread::wait"]
after 100
test destroy-busy-1 {thread::mutex destroy $dm} {!mutex is in use}
thread::send $d [list thread::mutex unlock $dm]
test destroy-busy-2 {thread::mutex destroy $dm} {}
thread::release $d

# A negative time limit of a condition wait is an error.
set nm [thread::mutex create]
set nc [thread::cond create]
thread::mutex lock $nm
test cond-neg-1 {thread::cond wait $nc $nm -1} {!timeout must be a positive integer}
thread::mutex unlock $nm
done
