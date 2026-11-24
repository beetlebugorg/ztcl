oo::class create C {
  variable n
  constructor {} { set n 0 }
  method add {k} { for {set i 0} {$i < $k} {incr i} { incr n $i }; return $n }
  method dead {} { [self] destroy; for {set i 0} {$i < 3} {incr i} { set n $i }; return $i }
}
set o [C new]; puts [$o add 10]; puts [$o add 10]; puts [$o dead]; puts [info commands $o]
set o [C new]; oo::objdefine $o method add {k} { return [list redefined [next $k]] }; puts [$o add 3]; puts [$o add 3]
