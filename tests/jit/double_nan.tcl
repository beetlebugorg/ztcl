# A NaN result of + - * / on doubles is a domain error, also in a loop
# that the JIT compiles. Each error comes from the instruction of the
# NaN, with the slots and the stack of the loop at that instruction.

proc quot {n} {
    set x 0.0
    set s 0.0
    for {set i 0} {$i < $n} {incr i} {
        set d [expr {double($n - 1 - $i)}]
        set s [expr {$s + $x / $d}]
        set x [expr {$x + 0.0}]
    }
    return $s
}

proc diff {n} {
    set big 1e308
    set inf [expr {$big * 10}]
    set s 0.0
    for {set i 0} {$i < $n} {incr i} {
        set a [expr {$i < $n - 1 ? 1.5 : $inf}]
        set s [expr {$s + ($a - $inf)}]
    }
    return $s
}

proc prod {n} {
    set z 1.0
    set inf [expr {1e308 * 10}]
    set k 0
    for {set i 0} {$i < $n} {incr i} {
        set z [expr {$z * 0.5}]
        if {$i == $n - 1} { set z 0.0 }
        set p [expr {$z * $inf}]
        incr k
    }
    return $k
}

foreach n {5 50 500} {
    foreach f {quot diff prod} {
        set r [catch {$f $n} m o]
        puts "$f $n: $r $m [dict get $o -errorcode]"
    }
}

# The slots keep the values of the loop before the error.
proc kept {n} {
    set j 0
    set y 3.0
    catch {
        for {set i 0} {$i < $n} {incr i} {
            set j $i
            if {$i == $n - 1} { set y 2.0 }
            set q [expr {($y - 2.0) / ($y - 2.0)}]
            set y [expr {$y + $q - 1.0}]
        }
    } m
    list $j $y $m
}
puts [kept 100]
puts "[catch {expr {0.0 / 0}} m] $m"
puts "[catch {expr {nan}} m] $m"
