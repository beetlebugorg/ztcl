# The JSON benchmark of tclsh with tcllib: tclsh bench_tcllib.tcl MODE FILE.json
# TCLLIB is the folder of the tcllib modules (it has json/json.tcl).
# Prints the best time of one run of MODE, in seconds, or "skip".
# SPDX-License-Identifier: BSD-2-Clause
lassign $argv mode file
lappend auto_path $env(TCLLIB)
package require json
set f [open $file]; fconfigure $f -encoding utf-8; set text [read $f]; close $f
proc walk {v} { return 1 }
switch -- $mode {
    parse { set op {json::json2dict $text} }
    default { puts skip; exit }
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
