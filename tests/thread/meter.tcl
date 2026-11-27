# Meters of ztcl#243: units of threads at the levels interp and process.
# thread-tests-flags: --allow meter,interp
# SPDX-License-Identifier: BSD-2-Clause

set work {
    proc fib n { if {$n < 2} { return $n }; expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]} }
    fib 14
}

# 1. The interp level.
thread::join [thread::create -joinable -meter a $work]
set a [ztcl::meter get a]
test meter-1 {expr {[dict get $a units] > 1000}} 1
test meter-2 {dict get $a threads} {interp 1 process 0}
test meter-3 {expr {[dict get $a wall_us] > 0}} 1

# 2. The process level gives the same units, from the child.
if {[catch {thread::create -joinable -isolation process -meter p $work} t opts]} {
    if {[lindex [dict get $opts -errorcode] 2] ni {LEVEL START}} {
        test meter-4 {set t} ok
    }
    puts "skip: $t"
} else {
    thread::join $t
    set p [ztcl::meter get p]
    test meter-5 {expr {[dict get $p units] == [dict get $a units]}} 1
    test meter-6 {dict get $p threads} {interp 0 process 1}
    test meter-7 {expr {[dict get $p process messages] >= 3}} 1
    test meter-8 {expr {[dict get $p process bytes] > 0}} 1
    test meter-9 {expr {[dict get $p wall_us] > 0}} 1
}

# 3. A budget across two threads.
ztcl::meter create b -budget 3000
set t1 [thread::create -joinable -meter b {while 1 {incr x}}]
set t2 [thread::create -joinable -meter b {while 1 {incr x}}]
thread::join $t1
thread::join $t2
test meter-10 {dict get [ztcl::meter get b] units} 3000
test meter-11 {dict get [ztcl::meter get b] left} 0

# 4. A meter of a thread that waits, read after each send.
set t [thread::create -meter w]
thread::send $t {set z 0}
set u1 [dict get [ztcl::meter get w] units]
thread::send $t {for {set i 0} {$i < 100} {incr i} {incr z}}
set u2 [dict get [ztcl::meter get w] units]
test meter-12 {expr {$u2 - $u1 > 200}} 1
thread::release $t

test meter-13 {lsort [ztcl::meter list]} {a b p w}
ztcl::meter delete a
test meter-14 {catch {ztcl::meter get a} m; set m} {no meter "a"}

done
