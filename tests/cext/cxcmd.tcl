# The checks of commands, scripts, results, and variables: tests/cext/cxcmd.c.
namespace eval cxcmd {}
puts [catch {load $dir/cxcmd.so} msg]:$msg
puts [package present cxcmd]
puts [cxcmd::add 1 2 39]
puts [catch {cxcmd::add 1 x} msg]:$msg
puts [cxcmd::run {expr {6 * 7}}]
puts [catch {cxcmd::run {error boom}} msg]:$msg
puts [catch {cxcmd::run} msg]:$msg
puts [catch {cxcmd::run {return -code break}} msg]:$msg
proc p {} { set cxin local; list [cxcmd::vars] $cxout $cxtext }
puts [p]
puts [catch {cxcmd::vars} msg]:$msg
puts [cxcmd::glob]:$cxg
puts [cxcmd::nre {string repeat ab 2}]
puts [catch {cxcmd::nre {error nre}} msg]:$msg
puts [cxcmd::count]
puts [cxcmd::drop cxcmd::add]:[cxcmd::count]:[info commands cxcmd::add]
puts [cxcmd::drop cxcmd::nosuch]
# A list crosses the bridge as a list, in both ways.
puts [cxcmd::shape [list a [list b c] {}]]
puts [cxcmd::shape [cxcmd::mklist]]
puts [cxcmd::varlist]:[llength $cxl]:[lindex $cxl 1 1]
puts [cxcmd::evalshape {list p [list q r]}]
puts [cxcmd::shape "a b"]
set l [cxcmd::mklist]
puts [llength $l]:[lindex $l 2]:[string length [lindex $l 3]]
# U+0000 is C0 80 in C, and one character in Tcl.
puts [cxcmd::bytes "a\0b"]
puts [cxcmd::bytes [list "x\0" y]]
set z [lindex [cxcmd::mklist] 3]
puts [string length $z]:[scan [string index $z 1] %c]
puts [cxcmd::run "string length {p\0q}"]
