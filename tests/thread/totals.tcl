# total_steps and total_mem stop a thread and leave the others running.
# thread-tests-flags: --thread-steps 400000 --threads-steps 1000000 --thread-mem 268435456 --threads-mem 134217728
# SPDX-License-Identifier: BSD-2-Clause

# Two threads get 400 000 steps each. The third gets the 200 000 that
# are left.
set a [thread::create]
set b [thread::create]
set c [thread::create -joinable {while 1 {}}]
test steps-1 {thread::join $c} 1
test steps-2 {thread::send $a {set n 0; for {set i 0} {$i < 10000} {incr i} {incr n}; set n}} 10000
# The steps that an ended thread did not use go back to the total.
thread::release -wait $a
set d [thread::create]
test steps-3 {thread::send $d {set n 0; for {set i 0} {$i < 10000} {incr i} {incr n}; set n}} 10000

# total_mem: one thread fills the group memory and stops. The others
# keep running.
set m [thread::create -joinable {set s x; while 1 {append s $s}}]
test mem-1 {thread::join $m} 1
test mem-2 {thread::send $d {string length [string repeat x 1000]}} 1000
test mem-3 {thread::send $b {expr {2 + 2}}} 4
foreach x [list $b $d] {thread::release -wait $x}
done
