# A large live set, 300,000 strings in a list, held while young garbage
# goes by: each collection marks the whole live set, so this shows the
# pause of a large heap.
set keep {}
for {set i 0} {$i < 300000} {incr i} { lappend keep [string repeat x [expr {16 + $i % 64}]] }
for {set i 0} {$i < 1500000} {incr i} {
    set s "tmp-$i"
    set t [string toupper $s]
}
set n [llength $keep]
