# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `switch -glob` with literal patterns and bodies
# compiles to `str_eq_jump` with a glob test.
proc g {x} {
    switch -glob -- $x {
        k0 {return zero}
        k1* {return one}
        *3 {return three}
        {[ab]?} {return ab}
        a\\* {return star}
        x - y* {return xy}
        default {return other}
    }
}
proc nodef {x} {switch -glob -- $x {a* {set r A} b* {set r B}}}
proc words {x} {switch -glob -- $x a* {return A} *z {return Z} default {return D}}
proc loop {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        switch -glob -- "k[expr {$i % 5}]" {k0 {incr s} k1* {incr s 2} *3 {incr s 3} default {incr s 4}}
    }
    return $s
}
proc num {x} {switch -glob -- $x {1* {return one} *9 {return nine} default {return D}}}
set r {}
foreach x {k0 k10 k1 a3 ab b9 {a*} a* x y yy z {} k} { lappend r [g $x] }
puts $r
puts [list [nodef apple] [nodef box] [nodef cat]]
puts [list [words abc] [words xyz] [words q]]
puts [loop 1000]
puts [list [num 15] [num 29] [num 7] [num [expr {10 + 9}]]]
puts [list [catch {switch -glob -- x {a {}}} m] $m]
