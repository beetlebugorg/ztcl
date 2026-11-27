# jit-fuzz: seed 662, mode jit-default, compute limit 2000000, memory limit 571635, stress 0, first failed allocation 20
set ::tc 0; set g0 0; set g1 x; set l {1 2 3}; set s {}; set dd {k0 1}
  set a -9223372036854775809; set b -2; set c 3; set d 18; set e 11; set f -2147483648; 
proc p0 {a b c d} {
  set l {1 2 3}; set s {}; set dd {k0 1}
  set e -2147483649; 
  set f -2147483648
  foreach {d b} {{1 2 3} {} 2147483648 007 -9223372036854775809 {x y z w} -1e-5 {} +5 -9223372036854775809 0b101 2.0 {1 2 3} 007 -2 -0.0 1e308 12 1 -2147483649 -9223372036854775808 2147483648 -1e-5} {
    foreach {d} {} {
      set e [expr {$b - -1}]
      if {($d eq -2)} continue
    }
    set d [expr {$b > 2}]
  }
  lassign $a b e e
  puts [list $e $l]
  if {$f != $d} {error oops}
  set e [llength $l]
  if {$b <= $d} {
    try {
      set c [string index $b $a]
      switch -exact -- $e {
        4294967295 {
          set c [expr {$d < $f}]
          set e [expr {$a & $b}]
        }
        -15 {
          set f $a
        }
        default {
          incr b 7
          set e [incr d 0]
        }
      }
    } on error {m o} {puts "t1e $m [dict get $o -errorcode]"} on 3 {} {puts t1b} on 4 {} {puts t1c}
    set rc [catch {
      switch $f {
        1e3 {
          set d [expr {-2}]
        }
        +5 {
          incr c
        }
        default {
          incr c $d
        }
      }
    } m]; puts "c2 $rc $m"; if {$rc == 1} {puts "c2ec $::errorCode"; puts "c2ei [lindex [split $::errorInfo \n] 0]"}
  } elseif {$f < 4294967295} {
    for {set i3 0} {$i3 < 33} {incr i3} {
      if {$i3 != $c} break
      incr b 16
    }
    set c [incr a 14]
  }
  uplevel #0 {incr ::tc}
  append s -0
}
proc p1 {a b c} {
  set l {1 2 3}; set s {}; set dd {k0 1}
  set d 3; set e 2147483647; set f -9223372036854775808; 
  eval [list set d [list 7 -9223372036854775809]]
  if {$b == 14} {error {two words}}
  foreach {e} {9223372036854775808 2 -16 0 9223372036854775807 -9223372036854775807 1e308 2147483647 1e308 3.0e2 5 no 0 -17 4294967295 -3 1e308} {
    set d [string length $a]
    incr c -18
  }
  incr d -9223372036854775808
  set d [incr d 4294967295]
}
proc p2 {a b c} {
  set l {1 2 3}; set s {}; set dd {k0 1}
  set d -9223372036854775807; set e -0; set f 0b101; 
  incr b 2
  incr e
  set a [p0 -8 $a [list 1e3 0.1] [expr {(($c && 9223372036854775808) + ($a == 9223372036854775807))}]]
  incr c
  return [list $l $s $e]
}
proc p3 {a b c d} {
  set l {1 2 3}; set s {}; set dd {k0 1}
  set e -18; set f -14; 
  set rc [catch {
    set e [llength $c]
    set w5 0; while {$w5 < 38} {incr w5; {
      puts [list $e $s]
      set a [append c -9223372036854775809]
      lassign $a d d
      if {$c > $c} {return -code error bad}
    }}
  } m]; puts "c4 $rc $m"; if {$rc == 1} {puts "c4ec $::errorCode"; puts "c4ei [lindex [split $::errorInfo \n] 0]"}
  set a [lindex $d end-1]
  for {set i6 0} {$i6 < 8} {incr i6} {
    foreach {a d} {2147483647} {
      set q [expr {abs((($b && $i6) + (4611686018427387904 * $i6)))}]
      set a [llength $e]
      incr d $a
    }
    set f [p2 $i6 $f $f]
    set a $e
  }
  set f [lassign $b d d d]
  set e [expr {$b - $c}]
  set d [lassign $a e e]
  append s 1e3
  switch $e {
    +5 {
      switch -exact -- $e {
        0x10 {
          set d [expr {$e > 9223372036854775807}]
        }
      }
      incr d $b
    }
    abc {
      set c 4294967295
    }
    { 12 } {
      uplevel #0 {incr ::tc}
      try {
        set b [incr f -19]
        incr b $a
      } on error {m o} {puts "t7e $m [dict get $o -errorcode]"} on 3 {} {puts t7b} on 4 {} {puts t7c}
    }
    default {
      set b [expr {$b == $c}]
      set a [list -2147483648 $f]
    }
  }
}
proc p4 {a} {
  set l {1 2 3}; set s {}; set dd {k0 1}
  set b 2; set c -9223372036854775807; set d -9223372036854775809; set e 7; set f 9223372036854775808; 
  set e $g0
  puts [list $e $l]
  incr d -9223372036854775807
  foreach {d d} $b {
    if {$a} {
      try {
        incr f $c
        lappend l 007 $f
      } on error {m o} {puts "t8e $m [dict get $o -errorcode]"} on 3 {} {puts t8b} on 4 {} {puts t8c}
      set f [yield $a]
      puts [list $a $dd]
    }
    foreach {d f} {{ 12 }} {
      set e [string length $e]
      set d [llength $c]
    }
    unset f
    set b [expr {($d / $f)}]
  }
  global g0 g1; incr g0; set e $g1
}
proc p5 {a b c} {
  set l {1 2 3}; set s {}; set dd {k0 1}
  set d -9223372036854775808; set e -12; set f 2; 
  set rc [catch {
    set p [expr {$f}]
  } m]; puts "c9 $rc $m"; if {$rc == 1} {puts "c9ec $::errorCode"; puts "c9ei [lindex [split $::errorInfo \n] 0]"}
  incr b
  set a [apply {{a {b 2}} {
    append s $f
    set d [incr f -9223372036854775809]
    set c [expr {!(wide(2.0) - (-1 && 10))}]
  }} -2]
  set e $c
  set e [incr d 10]
}
set rc [catch {
    if {$f > $c} {
      set rc [catch {
        set d [expr {(-1 - -($a <= $d ? $a : $d))}]
        set b 7
      } m]; puts "c10 $rc $m"; if {$rc == 1} {puts "c10ec $::errorCode"; puts "c10ei [lindex [split $::errorInfo \n] 0]"}
      set l [list [expr {(($d - $d) / (($a * $c) ? -9223372036854775808 : $f))}] 2.0 $f]
      set f [list -9223372036854775807 -2]
    } else {
      if {$b >= $a} {
        set p [expr {$a}]
        set f [incr d 6]
        unset -nocomplain f
      } elseif {$e == $e} {
        set e [incr e 4294967296]
      } else {
        set b [dict get $dd k0]
      }
      set b [p4 [expr {($e || $f)}]]
    }
} m]; puts "top $rc $m"; if {$rc == 1} {puts "topec $::errorCode"; puts "topei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {
    foreach {e c} $d {
      trace add variable c write {apply {{n1 n2 op} {incr ::tc}}}
      if {bool((-2147483649 == $a))} {error x {custom info} {A B C}}
    }
} m]; puts "top $rc $m"; if {$rc == 1} {puts "topec $::errorCode"; puts "topei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {
    set p [expr {bool($a)}]
} m]; puts "top $rc $m"; if {$rc == 1} {puts "topec $::errorCode"; puts "topei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p0 $e [expr {($d <= $e ? (-9223372036854775808 | $e) : ($b < -19 ? $f : $d))}] $d 2.0} m]; puts "r0 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p1 -2147483649 $e 007} m]; puts "r1 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p2 -9223372036854775807 4 $b} m]; puts "r2 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p3 9223372036854775807 $e {a b} -2} m]; puts "r3 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p4 1e300} m]; puts "r4 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p5 0x10 1 [list 0b101 {a b}]} m]; puts "r5 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p0 0x10 $d 4611686018427387904 $e} m]; puts "r0 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p1 -9223372036854775808 $b 10} m]; puts "r1 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p2 [list -2147483649 9] $b [expr {3037000500}]} m]; puts "r2 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p3 [expr {8}] $a [expr {$f}] $d} m]; puts "r3 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p4 [list 3037000500 abc]} m]; puts "r4 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
set rc [catch {p5 [expr {+("abc" % $f)}] [expr {~($f % 3037000500)}] -1} m]; puts "r5 $rc $m"; if {$rc == 1} {puts "rec $::errorCode"; puts "rei [lindex [split $::errorInfo \n] 0]"}
puts "tc $::tc g0 $g0"
