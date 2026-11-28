# The tsv commands, their errors, the keyed lists, and the locks.
# SPDX-License-Identifier: BSD-2-Clause

test set-1 {tsv::set a x 1} 1
test set-2 {tsv::set a x} 1
test set-3 {tsv::set a nope} {!no key a(nope)}
test set-4 {tsv::set nope x} {!"nope" is not a thread shared array}
test set-5 {tsv::set} {!wrong # args: should be "tsv::set array key ?args?"}
test get-1 {tsv::get a x} 1
test get-2 {list [tsv::get a x v] $v} {1 1}
test get-3 {tsv::get a nope v} 0
test get-4 {tsv::get a nope} {!no key a(nope)}
test get-5 {tsv::get nope x} {!"nope" is not a thread shared array}
test get-6 {tsv::get a} {!wrong # args: should be "tsv::get array key ?args?"}
test exists-1 {tsv::exists a x} 1
test exists-2 {tsv::exists a nope} 0
test exists-3 {tsv::exists a} {!wrong # args: should be "tsv::exists array key ?args?"}
test exists-4 {tsv::exists nope} {!wrong # args: should be "tsv::exists array key ?args?"}
test exists-5 {tsv::exists nope x} 0
test incr-1 {tsv::incr a n} 1
test incr-2 {tsv::incr a n 5} 6
test incr-3 {tsv::incr a n -2} 4
test incr-4 {tsv::set a s abc; tsv::incr a s} {!expected integer but got "abc"}
test incr-5 {tsv::incr a n x} {!expected integer but got "x"}
test incr-6 {tsv::incr a} {!wrong # args: should be "tsv::incr array key ?args?"}
test append-1 {tsv::append a s def} abcdef
test append-2 {tsv::append a s2 x y z} xyz
test append-3 {tsv::append a s} {!wrong # args: should be "tsv::append a s value ?value ...?"}
test pop-1 {tsv::pop a s} abcdef
test pop-2 {tsv::exists a s} 0
test pop-3 {tsv::pop a s} {!no key a(s)}
test move-1 {tsv::set a m 1; tsv::move a m m2; list [tsv::exists a m] [tsv::get a m2]} {0 1}
test move-2 {tsv::move a nope m3} {!no key a(nope)}
test move-3 {tsv::set a m 5; tsv::move a m m2; tsv::get a m2} {!key "m2" exists}
test unset-1 {tsv::unset a m2; tsv::exists a m2} 0
test unset-2 {tsv::unset a nope} {!no key a(nope)}
test unset-3 {tsv::set b x 1; tsv::unset b; tsv::exists b} {!wrong # args: should be "tsv::exists array key ?args?"}
test unset-4 {tsv::unset nope} {!"nope" is not a thread shared array}
test unset-5 {tsv::unset} {!wrong # args: should be "tsv::unset array ?key ...?"}
test names-1 {tsv::set c1 x 1; tsv::set c2 x 1; lsort [tsv::names c*]} {c1 c2}
test names-2 {expr {"a" in [tsv::names]}} 1
test names-3 {tsv::names a b} {!wrong # args: should be "tsv::names ?pattern?"}
test lappend-1 {tsv::lappend l x a b} {a b}
test lappend-2 {tsv::lappend l x {c d}} {a b {c d}}
test lappend-3 {tsv::lappend l x} {!wrong # args: should be "tsv::lappend l x value ?value ...?"}
test llength-1 {tsv::llength l x} 3
test llength-2 {tsv::set l bad "a \{b"; tsv::llength l bad} {!unmatched open brace in list}
test lindex-1 {tsv::lindex l x 1} b
test lindex-2 {tsv::lindex l x end} {c d}
test lindex-3 {tsv::lindex l x 10} {}
test lindex-4 {tsv::lindex l x} {!wrong # args: should be "tsv::lindex l x index"}
test lrange-1 {tsv::lrange l x 0 1} {a b}
test lrange-2 {tsv::lrange l x 1 end} {b {c d}}
test lsearch-1 {tsv::lsearch l x b} 1
test lsearch-2 {tsv::lsearch l x z} -1
test lsearch-3 {tsv::lsearch l x -glob {c*}} 2
test lsearch-4 {tsv::lsearch l x -exact {c d}} 2
test linsert-1 {tsv::linsert l x 1 p q; tsv::get l x} {a p q b {c d}}
test linsert-2 {tsv::linsert l x end r} {}
test lreplace-1 {tsv::lreplace l x 0 1 Z; tsv::get l x} {Z q b {c d} r}
test lreplace-2 {tsv::lreplace l x 0 0} {}
test lset-1 {tsv::set l y {a {b c} d}; tsv::lset l y 1 0 X} {a {X c} d}
test lset-2 {tsv::lset l y 2 Y} {a {X c} Y}
# Tcl 9 names the index in the message of lset, and Tcl 8.6 does not.
test lset-3 {tsv::lset l y 9 Y} [expr {[package vsatisfies [info patchlevel] 9-] ? {!index "9" out of range} : {!list index out of range}}]
test lpop-1 {tsv::set l z {a b c d}; tsv::lpop l z} a
test lpop-2 {tsv::lpop l z end} d
test lpop-3 {tsv::get l z} {b c}
test lpop-4 {tsv::lpop l z 9} {}
test lpush-1 {tsv::lpush l z X} {}
test lpush-2 {tsv::lpush l z Y end; tsv::get l z} {X b c Y}
test lpush-3 {tsv::lpush l z W 1; tsv::get l z} {X W b c Y}
test lpush-4 {tsv::lpush l q first; tsv::get l q} first
test kinds-1 {tsv::set k i [expr {3}]; tsv::set k d [expr {2.5}]; list [tsv::get k i] [tsv::get k d]} {3 2.5}
test array-1 {tsv::array set arr {a 1 b 2 c 3}; lsort [tsv::array names arr]} {a b c}
test array-2 {tsv::array size arr} 3
test array-3 {lsort -stride 2 [tsv::array get arr]} {a 1 b 2 c 3}
test array-4 {tsv::array get arr b} {b 2}
test array-5 {tsv::array names arr {[ab]}} {a b}
test array-6 {tsv::array reset arr {x 9}; tsv::array get arr} {x 9}
test array-7 {tsv::array set arr {a}} {!list must have an even number of elements}
test array-8 {tsv::array bogus arr} {!bad option "bogus": must be set, reset, get, names, size, or isbound}
test array-9 {tsv::array size nope} 0
test array-10 {tsv::array names nope} {}
test array-11 {tsv::array} {!wrong # args: should be "tsv::array option array"}
test keyl-1 {tsv::keylset kl k1 a 1 b 2} {}
test keyl-2 {tsv::get kl k1} {{a 1} {b 2}}
test keyl-3 {tsv::keylget kl k1 a} 1
test keyl-4 {tsv::keylget kl k1 nope} {!key "nope" not found}
test keyl-5 {list [tsv::keylget kl k1 nope v] [info exists v]} {0 1}
test keyl-6 {list [tsv::keylget kl k1 b v2] $v2} {1 2}
test keyl-7 {lsort [tsv::keylkeys kl k1]} {a b}
test keyl-8 {tsv::keylset kl k1 c.d 4; tsv::keylget kl k1 c.d} 4
test keyl-9 {tsv::keylkeys kl k1 c} d
test keyl-10 {tsv::keyldel kl k1 a; lsort [tsv::keylkeys kl k1]} {b c}
test keyl-11 {tsv::keyldel kl k1 nope} {!key "nope" not found}
test keyl-12 {tsv::keylget kl k1} {b c}
test keyl-13 {tsv::keylset kl k1 a} {!wrong # args: should be "tsv::keylset kl k1 key value ?key value ...?"}
test lock-1 {tsv::lock lk {tsv::set lk x 1; tsv::incr lk x}} 2
test lock-2 {catch {tsv::lock lk {tsv::set lk y 2; error inside}} m; list $m [tsv::get lk y]} {inside 2}
test lock-3 {tsv::lock lk tsv::get lk y} 2
test lock-4 {tsv::lock lk} {!wrong # args: should be "tsv::lock array arg ?arg...?"}
test object-1 {set o [tsv::object ob e]; $o set 5; $o incr 2; $o get} 7
test object-2 {$o lappend z; tsv::get ob e} {7 z}
test object-3 {tsv::object ob} {!wrong # args: should be "tsv::object array key ?args?"}
test handlers-1 {tsv::handlers} {}

# 8 threads, each with 10 000 tsv::incr on one element. The sum is exact.
tsv::set cnt n 0
set ts {}
for {set i 0} {$i < 8} {incr i} {
    lappend ts [thread::create -joinable {
        for {set k 0} {$k < 10000} {incr k} {tsv::incr cnt n}
    }]
}
foreach t $ts {thread::join $t}
test race-1 {tsv::get cnt n} 80000

# 8 threads on 8 arrays, and a list with lappend and lpop.
set ts {}
for {set i 0} {$i < 8} {incr i} {
    lappend ts [thread::create -joinable [list apply {{i} {
        for {set k 0} {$k < 2000} {incr k} {
            tsv::lappend q$i l $k
            tsv::incr q$i n
        }
        for {set k 0} {$k < 1000} {incr k} {tsv::lpop q$i l end}
    }} $i]]
}
foreach t $ts {thread::join $t}
set sum 0
for {set i 0} {$i < 8} {incr i} {incr sum [tsv::get q$i n]; incr sum [tsv::llength q$i l]}
test race-2 {set sum} 24000
test race-3 {tsv::lindex q3 l end} 999

# A thread that ends inside tsv::lock frees the lock.
set t [thread::create -joinable {tsv::lock held {tsv::set held x 1; thread::exit}}]
thread::join $t
test lock-end-1 {tsv::lock held {tsv::incr held x}} 2

# The lock of an array excludes the other threads while the script runs.
tsv::set ex v 0
set ts {}
for {set i 0} {$i < 4} {incr i} {
    lappend ts [thread::create -joinable {
        for {set k 0} {$k < 500} {incr k} {
            tsv::lock ex {set v [tsv::get ex v]; tsv::set ex v [expr {$v + 1}]}
        }
    }]
}
foreach t $ts {thread::join $t}
test lock-ex-1 {tsv::get ex v} 2000
done
