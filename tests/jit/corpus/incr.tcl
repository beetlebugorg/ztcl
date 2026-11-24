proc t {} {
  catch {incr nope} m; puts "unset: $m [info exists nope]"
  set arr(1) 1; catch {incr arr} m; puts "arr: $m"
  set tr 1; trace add variable tr write {apply {{a b c} {puts "trace $a"}}}
  incr tr; puts $tr
  trace add variable rd read {apply {{a b c} {upvar 1 $a v; set v 42}}}
  set rd 1; puts [expr {$rd + 1}]
  set s abc; catch {incr s} m; puts $m; puts $::errorCode
  set n 5; incr n [expr {2**62}]; puts $n
  set e ""; catch {incr e} m; puts $m
}
t; t; t
