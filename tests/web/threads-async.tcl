# The tests of the async mode of web/ztcl-threads.mjs: a page without
# cross-origin isolation. tools/wasm-threads.mjs runs the file in
# Chromium. A line "# ---- wait: EXPR" ends a step: the host runs the
# next step when EXPR is true, so the replies of the step can come.
# SPDX-License-Identifier: BSD-2-Clause
set main [thread::id]
test id-1 {set main} tid0x1
set t [thread::create {proc sq {x} {expr {$x * $x}}; thread::wait}]
test create-1 {thread::exists $t} 1
test names-1 {lsort [thread::names]} [lsort [list $main $t]]
test send-1 {thread::send -async $t {sq 7} ::r} {}
test send-2 {thread::send -async $t {list 1 2.5 abc [list x y]} ::kinds} {}
test send-3 {thread::send -async $t {error boom} ::e} {}
test wait-1 {thread::send $t {sq 2}} {!thread::send without -async needs a cross-origin isolated page (COOP and COEP headers)}
test wait-2 {thread::send $t {sq 2} v} {!thread::send without -async needs a cross-origin isolated page (COOP and COEP headers)}
test wait-3 {thread::wait} {!thread::wait in the main thread needs a cross-origin isolated page (COOP and COEP headers)}
test wait-4 {thread::join $t} {!thread::join needs a cross-origin isolated page (COOP and COEP headers)}
test wait-5 {thread::create -joinable {}} {!thread::create -joinable needs a cross-origin isolated page (COOP and COEP headers)}
test wait-6 {tsv::set a b c} {!tsv::set needs a cross-origin isolated page (COOP and COEP headers)}
test wait-7 {thread::mutex create} {!thread::mutex needs a cross-origin isolated page (COOP and COEP headers)}
test wait-8 {thread::release -wait $t} {!thread::release -wait needs a cross-origin isolated page (COOP and COEP headers)}
test wait-9 {vwait ::r} {!invalid command name "vwait"}
test bad-1 {thread::send -async tid0x99 {set x}} {!thread "tid0x99" does not exist}
set p [tpool::create -maxworkers 2 -initcmd {proc tw {x} {expr {$x * 3}}}]
set jobs {}
foreach x {1 2 3 4 5} {lappend jobs [tpool::post $p "tw $x"]}
test tpool-1 {llength $jobs} 5
test tpool-2 {tpool::wait $p $jobs} {!tpool::wait needs a cross-origin isolated page (COOP and COEP headers)}
# The limits of one thread: tools/wasm-threads.mjs sets a step limit of
# 1000000 and a memory limit of 32 MiB for each thread.
set lim [thread::create {thread::wait}]
thread::send -async $lim {while 1 {}} ::steps
set big [thread::create {thread::wait}]
thread::send -async $big {set s x; while 1 {append s $s}} ::mem
set b [thread::create {thread::wait}]
thread::broadcast {set ::got [thread::id]}
# ---- wait: {[info exists ::r] && [info exists ::kinds] && [info exists ::e]}
test send-4 {set ::r} 49
test send-5 {set ::kinds} {1 2.5 abc {x y}}
test send-6 {set ::e} boom
test broadcast-1 {thread::send -async $b {set ::got} ::bgot} {}
test broadcast-2 {thread::send -async $t {set ::got} ::tgot} {}
set done {}
# Gets the results of the jobs that are done. True when no job is left.
proc jobsDone {} {
    set left {}
    foreach j $::jobs {
        if {[catch {tpool::get $::p $j} r]} {lappend left $j} else {lappend ::done $r}
    }
    set ::jobs $left
    expr {[llength $left] == 0}
}
# ---- wait: {[info exists ::bgot] && [info exists ::tgot] && [jobsDone] && [info exists ::steps] && [info exists ::mem] && ![thread::exists $lim] && ![thread::exists $big]}
test limit-1 {set ::steps} {step limit reached}
test limit-2 {set ::mem} {the script used too much memory}
# A thread that passes a limit ends.
test limit-3 {list [thread::exists $lim] [thread::exists $big]} {0 0}
test broadcast-3 {set ::bgot} $b
test broadcast-4 {set ::tgot} $t
test tpool-3 {lsort -integer $::done} {3 6 9 12 15}
test tpool-4 {tpool::names} $p
test release-1 {thread::release $t; thread::release $b} 0
test release-2 {tpool::release $p} 0
# ---- wait: {[llength [thread::names]] == 1}
test release-3 {thread::names} $main
done
