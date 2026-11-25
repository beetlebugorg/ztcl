# The JSON benchmark of ztcl:
#   ztcl --allow channels,clock --root DATA bench_ztcl.tcl MODE FILE.json
# DATA has FILE.json and paths.json. Prints the best time of one run, in
# seconds, or "skip" when the build has no zt::json.
# SPDX-License-Identifier: BSD-2-Clause
lassign $argv mode file
if {[catch {package require zt::json}]} { puts skip; return }
proc slurp {name} {
    set f [open $name]
    fconfigure $f -encoding utf-8
    set t [read $f]
    close $f
    return $t
}
set text [slurp $file]
set paths [dict get [zt::json parse [slurp paths.json]] [string range $file 0 end-5]]
set q [dict get $paths query]
set reads [dict get $paths read]
proc walk {v} { return 1 }
switch -- $mode {
    validate { set op {zt::json valid $::text} }
    parse { set op {zt::json parse $::text} }
    query { set op {zt::json get $::text {*}$::q} }
    read3 { set op {foreach p $::reads { zt::json get $::text {*}$p }} }
    encode {
        set parsed [zt::json parse -typed $::text]
        set op {zt::json encode -typed $::parsed}
    }
    default { puts skip; return }
}
set best 1e9; set total 0.0; set n 0
while {$n < 3 || $total < 0.5} {
    set t [clock microseconds]
    eval $op
    set s [expr {([clock microseconds] - $t) / 1e6}]
    if {$s < $best} { set best $s }
    set total [expr {$total + $s}]
    incr n
}
puts $best
