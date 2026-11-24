# SPDX-License-Identifier: BSD-2-Clause
# The caches of a method call: the command of a name word, the call
# chain of an object, and the global cells of the declared variables.
# Each change of a class or an object between two calls must show.

oo::class create C {
    variable n
    constructor {} { set n 0 }
    method get {} { return "C$n" }
    method bump {} { incr n; return $n }
}
proc call {o m} { $o $m }
set a [C new]
set b [C new]
puts [list [call $a get] [call $a bump] [call $b bump] [call $b bump] [call $a get] [call $b get]]

# A new body of a method.
oo::define C method get {} { return "new$n" }
puts [call $a get]

# A mixin of one object.
oo::class create M { method get {} { return "M[next]" } }
oo::objdefine $a mixin M
puts [list [call $a get] [call $b get]]
oo::objdefine $a mixin
puts [call $a get]

# A filter of the class.
oo::define C {
    method Log {} { return "f[next]" }
    filter Log
}
puts [list [call $a get] [call $b bump]]
oo::define C filter -clear
puts [call $a get]

# Export and unexport.
oo::define C unexport get
puts [catch {call $a get} msg]
puts $msg
oo::define C export get
puts [call $a get]

# A method of the object, then its deletion.
oo::objdefine $b method get {} { return "own" }
puts [call $b get]
oo::objdefine $b deletemethod get
puts [call $b get]

# A rename of a method.
oo::define C renamemethod bump step
puts [catch {call $a bump} msg]
puts [call $a step]

# A new superclass.
oo::class create P { method hello {} { return "hello from P" } }
puts [catch {call $a hello}]
oo::define C superclass P
puts [call $a hello]

# A new class of the object.
oo::class create D { method get {} { return D } }
oo::objdefine $a class D
puts [call $a get]

# One site, many objects.
set objs {}
for {set i 0} {$i < 5} {incr i} { lappend objs [C new] }
set out {}
foreach o $objs { lappend out [call $o step] }
foreach o $objs { lappend out [call $o step] }
puts $out

# An object that ends, and a new object with the same name.
set name [C create obj1]
puts [call $name step]
$name destroy
puts [catch {call $name step}]
C create obj1
puts [call $name step]
puts [call obj1 step]

# A rename of the object command.
rename obj1 obj2
puts [catch {call obj1 step}]
puts [call obj2 step]

# Declared variables: a new declaration, unset, and set from outside.
oo::class create V {
    variable x
    constructor {} { set x 1 }
    method get {} { return $x }
}
set v [V new]
set w [V new]
puts [list [$v get] [$w get]]
set [info object namespace $v]::x 7
puts [list [$v get] [$w get]]
oo::define V variable x y
oo::define V method both {} { return "$x [info exists y]" }
puts [$v both]
oo::define V method sety {} { set y 3; return $y }
puts [list [$v sety] [$v both] [$w both]]
unset [info object namespace $w]::x
puts [catch {$w get}]
set [info object namespace $w]::x 9
puts [$w get]

# A method that calls a method of another object first.
oo::class create Pair {
    variable val other
    constructor {v o} { set val $v; set other $o }
    method get {} { return $val }
    method both {} { return [list [$other get] $val] }
}
set p1 [Pair new one {}]
set p2 [Pair new two $p1]
puts [$p2 both]

# `my` in two objects.
oo::class create My {
    variable k
    constructor {v} { set k $v }
    method inner {} { return $k }
    method outer {} { return [my inner] }
}
set m1 [My new first]
set m2 [My new second]
puts [list [$m1 outer] [$m2 outer] [$m1 outer]]
oo::define My method inner {} { return "inner $k" }
puts [$m2 outer]

# A call of the object from its filter has no filters, and the next
# call from outside has them again.
oo::class create F {
    method Wrap {} { return "w([my plain])[next]" }
    method plain {} { return p }
    method get {} { return g }
    filter Wrap
}
set f [F new]
puts [list [$f get] [$f plain] [$f get]]

# A private method that `my` called stays private for a call of the
# object command.
oo::class create H {
    method Hidden {} { return hidden }
    method open {} { return [my Hidden] }
}
set h [H new]
puts [$h open]
puts [catch {$h Hidden} msg]
puts $msg

# A name word that is not a literal names a new command after a rename.
proc target {} { return first }
proc via {f} { $f }
set f target
puts [via $f]
rename target old
proc target {} { return second }
puts [list [via $f] [via old]]
