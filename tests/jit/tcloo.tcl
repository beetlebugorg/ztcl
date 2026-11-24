# SPDX-License-Identifier: BSD-2-Clause
# Differential test: TclOO methods, constructors, next, and self.
oo::class create Base {
    variable total
    constructor {start} { set total $start }
    method add {n} { for {set i 0} {$i < $n} {incr i} { incr total $i }; return $total }
    method get {} { return $total }
}
oo::class create Child {
    superclass Base
    constructor {} { next 100 }
    method add {n} { set r [next $n]; return [expr {$r * 2}] }
    method who {} { return [list [self class] [self method]] }
}
set a [Child new]
puts [$a add 4]
puts [$a add 3]
puts [$a get]
puts [$a who]
$a destroy
