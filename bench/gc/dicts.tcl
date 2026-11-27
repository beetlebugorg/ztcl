# Dicts of 500 keys, filled and replaced 2,000 times: the hash tables and
# their entries.
for {set r 0} {$r < 2000} {incr r} {
    set d [dict create]
    for {set i 0} {$i < 500} {incr i} { dict set d k$i [list $r $i] }
    set size [dict size $d]
}
