proc t {} {
  set a 9223372036854775807; set b 1
  puts [expr {$a + $b}]; puts [expr {$a * 2}]; puts [expr {-$a - 2}]
  set c -9223372036854775808; puts [expr {$c - 1}]; puts [expr {$c * -1}]
  incr a; puts $a; incr a 9223372036854775807; puts $a
  set x 9223372036854775807; incr x -1; puts $x
  set y 0x10; incr y; puts $y
  set z " 5 "; incr z; puts $z
  set w 1e3; catch {incr w} m; puts $m
  set q 4611686018427387904; puts [expr {$q * 2}]; puts [expr {$q + $q}]
  set big 100000000000000000000; puts [expr {$big + 1}]; incr big; puts $big
  for {set i 9223372036854775805} {$i > 0 && $i < 9223372036854775815} {incr i} { puts $i }
  puts [expr {$i < 0}]
  set u 07; puts [expr {$u + 1}]
  set v 1_000; catch {expr {$v + 1}} m; puts $m
}
t; t
