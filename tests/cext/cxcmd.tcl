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
