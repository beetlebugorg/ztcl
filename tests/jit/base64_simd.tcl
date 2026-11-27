# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `binary encode` and `binary decode` of base64 and
# hex on texts of many lengths. The vector loops do the whole blocks,
# and the scalar code does the tail, the padding, the white space, and
# each error with its position.
proc bytes {n seed} {
    set r {}
    for {set i 0} {$i < $n} {incr i} { append r [format %c [expr {($i * 151 + $seed) % 256}]] }
    return $r
}
set lens {0 1 2 3 4 5 23 24 25 31 32 33 47 48 49 63 64 65 95 96 97 127 128 129 200 1000}
set out {}
foreach n $lens {
    set b [bytes $n 7]
    set e [binary encode base64 $b]
    set d [binary decode base64 $e]
    lappend out $n [string length $e] [string equal $d $b] [string range $e 0 40] [string range $e end-8 end]
    lappend out [binary encode base64 -maxlen 20 $b] [binary encode base64 -maxlen 8 -wrapchar | $b]
    set h [binary encode hex $b]
    lappend out [string range $h 0 30] [string equal [binary decode hex $h] $b]
}
puts $out
set t [binary encode base64 [bytes 400 3]]
set r {}
foreach pos {0 1 5 31 32 33 63 64 100 200 400 532} {
    # White space: skipped, or an error with -strict.
    foreach ch {{ } "\n" "\t"} {
        set m [string replace $t $pos $pos $ch]
        lappend r $pos [scan $ch %c] [catch {binary decode base64 $m} v] [string length $v] [catch {binary decode base64 -strict $m} v2] $v2
        set m [string range $t 0 $pos-1]$ch[string range $t $pos end]
        lappend r [catch {binary decode base64 $m} v] [string equal $v [binary decode base64 $t]]
    }
    # Other characters: an error with -strict.
    foreach ch {! - _ .} {
        set m [string replace $t $pos $pos $ch]
        lappend r [catch {binary decode base64 -strict $m} v2] $v2
    }
}
puts $r
puts [list [binary decode base64 "YWJj\nZGVm"] [binary decode base64 "YW Jj ZG Vm"] [binary decode base64 YQ==] [binary decode base64 YQ]]
puts [list [catch {binary decode hex "4g"} m] $m [binary decode hex "41 42\n43"]]
set big [string repeat "abcXYZ019+/" 3000]
puts [string equal [binary encode base64 [binary decode base64 $big]] $big]
puts [string length [binary decode base64 $big]]
set hb [bytes 300 11]
set hx [binary encode hex $hb]
puts [list [string equal [binary decode hex [string toupper $hx]] $hb] [string equal [binary decode hex $hx] $hb] [string length $hx]]
foreach pos {0 1 31 32 33 64 100 599} {
    set m [string replace $hx $pos $pos g]
    lappend hr $pos [catch {binary decode hex $m} v] $v
    set m [string range $hx 0 $pos-1]\n[string range $hx $pos end]
    lappend hr [string equal [binary decode hex $m] $hb] [catch {binary decode hex -strict $m} v] $v
}
puts $hr
