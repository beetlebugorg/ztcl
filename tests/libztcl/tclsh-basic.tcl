# A script of tools/libztcl/tclsh.sh: the tclsh of tclAppInit.c on
# libtcl8.6 and on libztcl gives the same output.
# SPDX-License-Identifier: BSD-2-Clause
puts "argc $argc argv {$argv} interactive $tcl_interactive"
puts "script [file tail [info script]] argv0 [file tail $argv0]"
namespace eval ::geo {
    variable count 0
    proc area {w h} { variable count; incr count; expr {$w * $h} }
}
puts "area [::geo::area 3 4] [::geo::area 5 6] count $::geo::count"
puts "regexp [regexp -inline {(\d+)-(\d+)} "x 10-20 y"]"
puts "regsub [regsub -all {o} "foo boo" 0]"
puts "string [string map {a 1 b 2} abcab] [string repeat ab 3] [string reverse hello]"
puts "clock [clock format 86400 -format %Y-%m-%d -gmt 1]"
puts "scan [scan "12 abc 3.5" "%d %s %f"]"
puts "binary [binary encode hex [binary format S 258]]"
set dir [file join [pwd] work]
file mkdir $dir
set f [open [file join $dir a.txt] w]
puts $f "line 1\nline 2"
close $f
set f [open [file join $dir a.txt]]
set lines [split [string trim [read $f]] \n]
close $f
puts "file [llength $lines] [lindex $lines end] size [file size [file join $dir a.txt]]"
puts "glob [lmap p [glob -directory $dir *] {file tail $p}]"
file delete -force $dir
puts "exec [exec echo hi there]"
set s [socket -server {apply {{c a p} {puts $c pong; close $c}}} 0]
set port [lindex [fconfigure $s -sockname] 2]
set c [socket 127.0.0.1 $port]
fileevent $c readable [list apply {{c} {set ::reply [gets $c]; close $c}} $c]
vwait ::reply
close $s
puts "socket $::reply"
catch {error inner} msg opts
puts "catch $msg [dict get $opts -code] [dict get $opts -errorcode]"
exit 2
