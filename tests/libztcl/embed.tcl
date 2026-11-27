# The script of tools/libztcl/check.sh: the same output on libtcl8.6
# and on libztcl.
# SPDX-License-Identifier: BSD-2-Clause
puts "embed $embed argc $argc argv {$argv}"
puts "argv0 [file tail $argv0] interactive $tcl_interactive"
puts "sum [sum 1 2 3 40]"
puts "rev [rev {a b {c d} e}]"
puts "catch [catch {sum 1 x} msg] $msg"
puts "catch [catch {rev} msg] $msg"
proc fib n { expr {$n < 2 ? $n : [fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]} }
puts "fib [fib 20]"
set d [dict create a 1 b 2]
dict incr d a 10
puts "dict $d"
puts "format [format %05.2f 3.14159] [string toupper abc] [lsort -integer {10 2 33 4}]"
set f [file join [file dirname [info script]] embed.tcl]
puts "script [file tail [info script]] exists [file exists $f]"
set n 0
foreach w [split "one two three" " "] { incr n [string length $w] }
puts "letters $n"
after 10 {set done 1}
vwait done
puts "vwait $done"
puts "nameofexecutable [expr {[info nameofexecutable] ne {}}]"
if {[llength $argv] && [lindex $argv 0] eq "exit"} { exit [lindex $argv 1] }
