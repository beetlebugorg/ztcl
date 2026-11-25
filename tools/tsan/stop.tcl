# A cancel of a thread in a loop. thread::cancel stores zero in
# mem_limit of the thread, and the loop reads mem_limit at each step, so
# ThreadSanitizer reports the pair when it runs with no suppression.
# Each tsv::incr locks a mutex, and the lock gives the loop of the thread
# new epochs of ThreadSanitizer. In a loop with no lock, such as
# `while 1 {}`, ThreadSanitizer gave no report of this pair.
# SPDX-License-Identifier: BSD-2-Clause
tsv::set a x 0
set c [thread::create]
thread::send -async $c {catch {while 1 {tsv::incr a x}} m; set ::m $m}
after 500
thread::cancel $c
after 200
puts [thread::send $c {set ::m}]
