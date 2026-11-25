# Two threads run tsv::incr at the same time. A runner built with
# -Dtsan-plant=true adds 1 to one global word in each tsv::incr with no
# lock, so ThreadSanitizer reports a race in tsv.opIncr.
# SPDX-License-Identifier: BSD-2-Clause
tsv::set a x 0
set t [thread::create -joinable {for {set k 0} {$k < 20000} {incr k} {tsv::incr a x}}]
for {set k 0} {$k < 20000} {incr k} {tsv::incr a x}
thread::join $t
puts [tsv::get a x]
