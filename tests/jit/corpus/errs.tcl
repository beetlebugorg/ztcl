proc a {x} { for {set i 0} {$i < 3} {incr i} { if {$i == $x} { error "boom $i" "info $i" {CODE $i} } } }
proc b {} { set s 0; foreach x {1 2 3} { incr s [expr {$x / 0}] } }
proc c {} { return -code 5 -level 1 hi }
proc d {} { return -code error -errorcode {X Y} -level 2 deep }
proc e {} { d; puts never }
proc f {} { while 1 { break }; foreach x {1 2} { continue }; return ok }
proc g {} { set r {}; for {set i 0} {$i < 5} {incr i} { lappend r [catch {if {$i % 2} continue; set i} m] $m } ; return $r }
proc h {} { break }
proc k {} { set r {}; foreach x {1 2 3} { lappend r [catch h m] } ; return $r }
proc l {} { foreach x {1 2 3} { h } ; return after }
foreach p {{a 1} b c e f g k l} {
  set r [catch $p m o]
  puts "$p -> $r <$m> [dict get $o -errorcode] <[expr {[dict exists $o -errorinfo] ? [dict get $o -errorinfo] : {}}]>"
}
foreach p {{a 1} b c e f g k l} {
  set r [catch $p m o]
  puts "$p -> $r <$m> [dict get $o -errorcode] [dict get $o -errorline]"
}
