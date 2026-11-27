# Short strings at a high rate, with little live data: the cost of the
# allocation and of the sweep of young garbage.
set n 0
for {set i 0} {$i < 2000000} {incr i} {
    set s "item-$i-[expr {$i * 7}]"
    incr n [string length $s]
}
