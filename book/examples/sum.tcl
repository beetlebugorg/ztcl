proc sum {n} {
    set total 0
    for {set i 0} {$i < $n} {incr i} {
        incr total $i
    }
    return $total
}
puts [sum 10000000]
