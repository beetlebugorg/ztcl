# 64 threads that start and end in a loop, 200 times.
# thread-tests-flags: --threads 64
# SPDX-License-Identifier: BSD-2-Clause

set ok 0
for {set round 0} {$round < 200} {incr round} {
    set ts {}
    for {set i 0} {$i < 64} {incr i} {lappend ts [thread::create -joinable {expr 1}]}
    foreach t $ts {incr ok [expr {[thread::join $t] == 0}]}
}
test churn-1 {set ok} 12800
test churn-2 {llength [thread::names]} 1
done
