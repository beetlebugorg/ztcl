# A reader of a parsed document for docs/dev/values.md:
#   ztcl --allow channels,clock --root DATA --tclsh read_ztcl.tcl FILE.json N
# Prints the time of one read.
# SPDX-License-Identifier: BSD-2-Clause
lassign $argv file n
package require zt::json
set f [open $file]; fconfigure $f -encoding utf-8; set text [read $f]; close $f
set doc [zt::json parse -null {} $text]
proc rd_twitter {doc} {
  set c 0
  foreach s [dict get $doc statuses] {
    incr c [string length [dict get $s user screen_name]]
    incr c [dict get $s retweet_count]
  }
  return $c
}
proc rd_citm_catalog {doc} {
  set c 0
  foreach p [dict get $doc performances] {
    incr c [llength [dict get $p seatCategories]]
    if {[dict get $p venueCode] eq "PLEYEL_PLEYEL"} { incr c }
  }
  dict for {k v} [dict get $doc areaNames] { incr c [string length $v] }
  return $c
}
proc rd_canada {doc} {
  set s 0.0
  foreach feat [dict get $doc features] {
    foreach ring [dict get $feat geometry coordinates] {
      foreach pt $ring { lassign $pt x y; set s [expr {$s + $x - $y}] }
    }
  }
  return $s
}
set name [string range $file 0 end-5]
set t [clock microseconds]
for {set i 0} {$i < $n} {incr i} { set r [rd_$name $doc] }
set us [expr {([clock microseconds]-$t)/double($n)}]
puts [format "read %s %.1f us (%.1f MB/s of JSON) r=%s" $file $us [expr {[string length $text]/$us}] $r]
