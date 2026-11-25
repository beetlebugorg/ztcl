# 8 threads with 100 000 tsv::incr each on one element, then on 8
# elements. Prints the two times in milliseconds.
# SPDX-License-Identifier: BSD-2-Clause
package require Thread
proc run {script} {
    set ts {}
    for {set i 0} {$i < 8} {incr i} {lappend ts [thread::create -joinable [list apply [list {i} $script] $i]]}
    set t0 [clock milliseconds]
    tsv::set go now 1
    foreach t $ts {thread::join $t}
    tsv::unset go
    return [expr {[clock milliseconds] - $t0}]
}
tsv::set c one 0
set one [run {
    while {![tsv::exists go now]} {after 1}
    for {set k 0} {$k < 100000} {incr k} {tsv::incr c one}
}]
for {set i 0} {$i < 8} {incr i} {tsv::set c e$i 0}
set eight [run {
    while {![tsv::exists go now]} {after 1}
    for {set k 0} {$k < 100000} {incr k} {tsv::incr c e$i}
}]
set sum 0
for {set i 0} {$i < 8} {incr i} {incr sum [tsv::get c e$i]}
puts "tsv-one $one [tsv::get c one]"
puts "tsv-eight $eight $sum"
