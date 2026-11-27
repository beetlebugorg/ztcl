# thread::create -caps: a thread with a subset of the capabilities of
# its creator, at the levels interp and process.
# thread-tests-flags: --allow interp
# SPDX-License-Identifier: BSD-2-Clause

# 1. The interp level.
set t [thread::create -caps {}]
test caps-1 {thread::send $t {info commands thread::*}} {}
test caps-2 {thread::send $t {list [info commands after] [info commands clock] [info commands interp]}} {{} {} {}}
test caps-3 {thread::send $t {expr {6 * 7}}} 42
thread::release $t

set t [thread::create -caps {clock thread}]
test caps-4 {thread::send $t {list [llength [info commands clock]] [info commands after]}} {1 {}}
test caps-5 {thread::send $t {expr {[llength [info commands thread::*]] > 0}}} 1
thread::release $t

# 2. Errors.
test caps-6 {catch {thread::create -caps {exec}} m o; list $m [dict get $o -errorcode]} {{the creator has no capability "exec"} {THREAD CAPS}}
test caps-7 {catch {thread::create -caps {nope}} m; set m} {unknown capability "nope"}

# 3. The process level: no thread::send to the parent.
if {[catch {thread::create -isolation process -caps {}} t opts]} {
    if {[lindex [dict get $opts -errorcode] 2] ni {LEVEL START}} {
        test caps-8 {set t} ok
    }
    puts "skip: $t"
} else {
    test caps-9 {thread::send $t {info commands thread::*}} {}
    test caps-10 {thread::send $t {info commands tsv::*}} {}
    test caps-11 {thread::send $t {list [info commands interp] [info commands open]}} {{} {}}
    test caps-12 {thread::send $t {string repeat ab 3}} ababab
    thread::release $t
}

done
