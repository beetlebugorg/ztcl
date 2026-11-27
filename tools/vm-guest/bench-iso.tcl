# The same scripts on the host, in a thread of each isolation level
# (interp, process, vm), and the start cost of each level (ztcl#468).
# Run with the runner of the host and the guest of the level vm:
#   ZTCL_VM_ISO_KERNEL=bzImage ZTCL_VM_ISO_INITRD=iso.cpio \
#     ztcl --allow vm,clock,thread bench-iso.tcl
# Each number is the best of 5 runs, in ms.
set procs {
    proc fib {n} { if {$n < 2} { return $n }; expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]} }
    proc loop {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s $i }; return $s }
    proc strs {n} {
        set l {}
        for {set i 0} {$i < $n} {incr i} { lappend l [string repeat x [expr {$i % 50}]] }
        string length [join $l ,]
    }
    proc dicts {n} {
        set d {}
        for {set i 0} {$i < $n} {incr i} { dict set d k$i $i }
        set s 0
        dict for {k v} $d { incr s $v }
        return $s
    }
    proc best {script} {
        set b {}
        for {set i 0} {$i < 5} {incr i} {
            set t0 [clock microseconds]
            uplevel #0 $script
            set t [expr {([clock microseconds] - $t0) / 1000.0}]
            if {$b eq {} || $t < $b} { set b $t }
        }
        return [format %.2f $b]
    }
}
set tests {{fib 24} {loop 1000000} {strs 100000} {dicts 100000}}
eval $procs
set row [list host]
foreach t $tests { lappend row [best $t] }
puts [join [list level start {*}$tests] " | "]
puts "[join [linsert $row 1 -] { | }]"
foreach level {interp process vm} {
    set starts {}
    for {set i 0} {$i < 5} {incr i} {
        set t0 [clock microseconds]
        set id [thread::create -joinable -isolation $level {thread::wait}]
        thread::send $id {set ready 1}
        lappend starts [expr {([clock microseconds] - $t0) / 1000.0}]
        if {$i < 4} { thread::release $id; thread::join $id }
    }
    thread::send $id $procs
    set row [list $level [format %.2f [lindex [lsort -real $starts] 0]]]
    foreach t $tests { lappend row [thread::send $id [list best $t]] }
    puts [join $row " | "]
    thread::release $id
    thread::join $id
}
