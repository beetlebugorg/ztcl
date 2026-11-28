# The test of the commands of ztcl::fhe. Run it with a build that has the
# module: zig build -Dmod-fhe=true, then ztcl tests/fhe/api.tcl. The
# script prints "ok" and the count of checks, or stops at the first
# failed check.
package require ztcl::fhe

set checks 0
proc near {what got want tol} {
    foreach g $got w $want {
        if {abs($g - $w) > $tol} {error "$what: got {$got}, want {$want}"}
    }
    incr ::checks
}
proc fails {what code script} {
    if {![catch {uplevel 1 $script} msg opts]} {error "$what: no error"}
    if {[dict get $opts -errorcode] ne $code} {error "$what: error code [dict get $opts -errorcode]: $msg"}
    incr ::checks
}

# CKKS at the size 8192: two levels.
set ctx [ztcl::fhe context ckks]
near "context" [list [dict get [ztcl::fhe info $ctx] slots] [dict get [ztcl::fhe info $ctx] bits]] {4096 200} 0
set keys [ztcl::fhe keys $ctx -sum 4 -rotations {-1}]
set a [ztcl::fhe encrypt $keys {1.5 2.0 -3.0 0.25}]
set b [ztcl::fhe encrypt $keys {2.0 0.5 1.0 4.0}]
near "decrypt" [ztcl::fhe decrypt $keys $a 4] {1.5 2.0 -3.0 0.25} 1e-6
near "add" [ztcl::fhe decrypt $keys [ztcl::fhe add $a $b] 4] {3.5 2.5 -2.0 4.25} 1e-6
near "add scalar" [ztcl::fhe decrypt $keys [ztcl::fhe add $a 10] 4] {11.5 12.0 7.0 10.25} 1e-6
near "add list" [ztcl::fhe decrypt $keys [ztcl::fhe add $a {1 2 3 4}] 4] {2.5 4.0 0.0 4.25} 1e-6
near "mul" [ztcl::fhe decrypt $keys [ztcl::fhe mul $a $b] 4] {3.0 1.0 -3.0 1.0} 1e-5
near "mul scalar" [ztcl::fhe decrypt $keys [ztcl::fhe mul $a -2] 4] {-3.0 -4.0 6.0 -0.5} 1e-5
near "mul list" [ztcl::fhe decrypt $keys [ztcl::fhe mul $a {1 2 3 4}] 4] {1.5 4.0 -9.0 1.0} 1e-5
near "rotate" [ztcl::fhe decrypt $keys [ztcl::fhe rotate $a 1] 3] {2.0 -3.0 0.25} 1e-5
near "rotate right" [ztcl::fhe decrypt $keys [ztcl::fhe rotate $a -1] 3] {0.0 1.5 2.0} 1e-5
near "dot" [ztcl::fhe decrypt $keys [ztcl::fhe dot $a $b 4] 1] {2.0} 1e-5
near "dot list" [ztcl::fhe decrypt $keys [ztcl::fhe dot $a {2.0 0.5 1.0 4.0}] 1] {2.0} 1e-5
# Two levels: the third product in sequence fails.
set p2 [ztcl::fhe mul [ztcl::fhe mul $a $b] $b]
near "two products" [ztcl::fhe decrypt $keys $p2 4] {6.0 0.5 -3.0 4.0} 1e-4
fails "no level" {ZTCL FHE NOLEVEL} {ztcl::fhe mul $p2 $b}
fails "no key" {ZTCL FHE NOKEY} {ztcl::fhe rotate $a 7}
fails "in use" {ZTCL FHE INUSE} {ztcl::fhe free $keys}
fails "handle" {ZTCL FHE HANDLE} {ztcl::fhe info fhe999}
fails "levels" {ZTCL FHE PARAMS} {ztcl::fhe context ckks -levels 3}

# The logistic regression score of docs/modules/fhe.md.
set ctx2 [ztcl::fhe context ckks -n 16384]
set keys2 [ztcl::fhe keys $ctx2 -sum 4]
set x [ztcl::fhe encrypt $keys2 {0.5 -1.25 2.0 0.75}]
set y [ztcl::fhe add [ztcl::fhe dot $x {0.8 0.1 -0.4 1.5}] 0.3]
set y3 [ztcl::fhe mul [ztcl::fhe mul $y $y] [ztcl::fhe mul $y -0.004]]
set score [ztcl::fhe add [ztcl::fhe add $y3 [ztcl::fhe mul $y 0.197]] 0.5]
set py [expr {0.5*0.8 - 1.25*0.1 - 2.0*0.4 + 0.75*1.5 + 0.3}]
near "score" [ztcl::fhe decrypt $keys2 $score 1] [list [expr {0.5 + 0.197*$py - 0.004*$py**3}]] 1e-4
puts "score [ztcl::fhe decrypt $keys2 $score 1]"

# TFHE: a one-bit full adder.
set tk [ztcl::fhe keys [ztcl::fhe context tfhe]]
foreach {x y} {0 0 0 1 1 0 1 1} {
    set ca [ztcl::fhe encrypt $tk $x]
    set cb [ztcl::fhe encrypt $tk $y]
    near "xor $x $y" [ztcl::fhe decrypt $tk [ztcl::fhe gate xor $ca $cb]] [expr {$x ^ $y}] 0
    near "and $x $y" [ztcl::fhe decrypt $tk [ztcl::fhe gate and $ca $cb]] [expr {$x & $y}] 0
    near "not $x" [ztcl::fhe decrypt $tk [ztcl::fhe not $ca]] [expr {!$x}] 0
}
set n [llength [info commands ztcl::fhe]]
ztcl::fhe free $a $b
puts "ok $checks"
