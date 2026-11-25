# A list that a cell owns, the kept frames, and the caches of TclOO
# with threads. A value that goes to another thread is a copy, so an
# `lset` in place on one side does not change the other side.
# SPDX-License-Identifier: BSD-2-Clause

# The procs of both sides. `run` keeps the tape in an owned cell: the
# reads go through `llength` and `lindex`, and the `lset` is the last
# command of a `switch` arm whose result is dropped.
set procs {
    proc run {tape n} {
        for {set i 0} {$i < $n} {incr i} {
            set pos [expr {$i % [llength $tape]}]
            switch -- [expr {$i % 2}] {
                0 {lset tape $pos [expr {[lindex $tape $pos] + 1}]}
                1 {lset tape $pos [expr {[lindex $tape $pos] + 2}]}
            }
            if {$i == $n / 2} {
                tsv::set owned mid $tape
                set ::mid $tape
            }
        }
        return $tape
    }
    proc fill {n} {
        set l {}
        for {set i 0} {$i < $n} {incr i} {lappend l 0}
        return $l
    }
    oo::class create Counter {
        variable n
        constructor {} {set n 0}
        method add {k} {incr n $k}
        method get {} {return $n}
    }
    proc count {k} {
        set c [Counter new]
        for {set i 0} {$i < $k} {incr i} {$c add $i}
        set r [$c get]
        $c destroy
        return $r
    }
}
eval $procs

set t [thread::create]
thread::send $t $procs

test owned-1 {run [fill 4] 8} {2 4 2 4}
test owned-2 {tsv::get owned mid} {2 2 1 2}
test owned-3 {set ::mid} {2 2 1 2}

# The copy in the other thread changes in place there, and the value of
# this thread stays.
set tape [run [fill 4] 8]
test owned-4 {thread::send $t [list run $tape 8]} {4 8 4 8}
test owned-5 {set tape} {2 4 2 4}
test owned-6 {tsv::get owned mid} {4 6 3 6}

# A value from the other thread is a new value here.
set back [thread::send $t {set l [fill 3]; lset l 1 7; set l}]
test owned-7 {run $back 3} {1 9 1}
test owned-8 {set back} {0 7 0}

# Both threads run the same procs and methods at one time. Each one has
# its own kept frames, command sites, and call chains.
thread::send -async $t {set ::r [list [run [fill 8] 2000] [count 500]]} done
test owned-9 {list [run [fill 8] 2000] [count 500]} {{250 500 250 500 250 500 250 500} 124750}
vwait done
test owned-10 {thread::send $t {set ::r}} {{250 500 250 500 250 500 250 500} 124750}

thread::release $t
done
