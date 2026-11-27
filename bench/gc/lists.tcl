# Lists of 1,000 strings, built and dropped 2,000 times: blocks of
# middle sizes and the buffers of growing lists.
for {set r 0} {$r < 2000} {incr r} {
    set l {}
    for {set i 0} {$i < 1000} {incr i} { lappend l "v$r.$i" }
    set total [llength $l]
}
