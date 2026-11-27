# A peak of about 200 MB of strings, then a small live set and light
# work: the memory that the process holds after a peak (`rss` against
# `rss_peak`, `heap_bytes` against `heap_peak`).
set big {}
for {set i 0} {$i < 200000} {incr i} { lappend big [string repeat y 1000] }
set big {}
set small {}
for {set i 0} {$i < 1000000} {incr i} {
    set s "after-$i"
    if {$i % 1000 == 0} { lappend small $s }
}
ztcl::gc collect
