# SPDX-License-Identifier: BSD-2-Clause
# Differential test: a string that `binary` made or read keeps its byte
# form, and each later use of the string gives the same result as a
# conversion.
set raw {}
for {set i 0} {$i < 1000} {incr i} { append raw [format %c [expr {($i * 97 + 3) % 256}]] }
set e [binary encode base64 $raw]
set d [binary decode base64 $e]
puts [list [string equal $d $raw] [string length $d] [string equal [binary encode base64 $d] $e]]
puts [string equal [binary encode hex $d] [binary encode hex $raw]]
binary scan $d cu5H8 head hx
puts [list $head $hx]
set f [binary format a*c3 $d {200 201 255}]
puts [list [string length $f] [string equal [binary encode base64 $f] [binary encode base64 $raw\xc8\xc9\xff]]]
set h [binary decode hex [binary encode hex $raw]]
puts [list [string equal $h $raw] [string equal [string range $h 10 20] [string range $raw 10 20]]]
# A string with characters above 255 has no byte form of its own.
set w [string repeat "Āÿ" 200]
puts [binary encode hex [string range [binary format a* $w] 0 7]]
puts [string equal [binary encode base64 $w] [binary encode base64 $w]]
for {set k 0} {$k < 3} {incr k} { lappend r [binary encode base64 [string range $d 0 300]] }
puts [llength [lsort -unique $r]]
