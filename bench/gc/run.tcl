# Runs each GC benchmark in a process of its own and prints a table of
# the counts of the collector (`ztcl::gc stats`). The program runs
# measure.tcl, which runs the script with fresh counts.
#
#   ztcl --allow exec,file,clock,channels --tclsh bench/gc/run.tcl ZTCL ?-runs N? ?SCRIPT ...?
#
# ZTCL is the ztcl program to measure. With no SCRIPT, the scripts of
# bench/gc. Each script runs N times (3 by default); the table has the
# median of each count. A script of bench/ works too: the counts cover
# the whole script.
set here [file dirname [info script]]
set ztcl [lindex $argv 0]
set runs 3
set scripts {}
for {set i 1} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {$a eq "-runs"} {
        set runs [lindex $argv [incr i]]
    } else {
        lappend scripts $a
    }
}
if {[llength $scripts] == 0} {
    foreach name {strings lists dicts live peak recurse} { lappend scripts [file join $here $name.tcl] }
}

proc median {l} {
    set s [lsort -real $l]
    return [lindex $s [expr {[llength $s] / 2}]]
}

set cols {
    wall_ms {Wall ms} collections {GCs} gc_ms {GC ms} p50_us {p50 us} p99_us {p99 us} max_us {max us}
    heap_peak_mb {Heap peak MB} heap_mb {Heap end MB} rss_mb {RSS end MB} rss_peak_mb {RSS peak MB} rate_mbs {Alloc MB/s}
}
set head [list Script]
foreach {k label} $cols { lappend head $label }
puts "| [join $head { | }] |"
puts "|[string repeat {---|} [llength $head]]"
foreach script $scripts {
    set rows {}
    for {set r 0} {$r < $runs} {incr r} {
        set out [exec $ztcl --allow meter,file,clock,channels,event --tclsh [file join $here measure.tcl] $script]
        set line [lsearch -inline [split $out \n] {GCSTATS *}]
        if {$line eq ""} { error "no counts from $script" }
        lassign [lrange $line 1 2] s wall
        set mb [expr {1024.0 * 1024.0}]
        dict set row wall_ms [expr {$wall / 1e6}]
        dict set row collections [dict get $s collections]
        dict set row gc_ms [expr {[dict get $s gc_ns] / 1e6}]
        dict set row p50_us [expr {[dict get $s pause_p50_ns] / 1e3}]
        dict set row p99_us [expr {[dict get $s pause_p99_ns] / 1e3}]
        dict set row max_us [expr {[dict get $s pause_max_ns] / 1e3}]
        dict set row heap_peak_mb [expr {[dict get $s heap_peak] / $mb}]
        dict set row heap_mb [expr {[dict get $s heap_bytes] / $mb}]
        dict set row rss_mb [expr {[dict get $s rss] / $mb}]
        dict set row rss_peak_mb [expr {[dict get $s rss_peak] / $mb}]
        # The rate over the wall time of the script, with no wait of measure.tcl.
        dict set row rate_mbs [expr {[dict get $s allocated] / $mb / ($wall / 1e9)}]
        lappend rows $row
    }
    set cells [list [file rootname [file tail $script]]]
    foreach {k label} $cols {
        set v [median [lmap row $rows {dict get $row $k}]]
        lappend cells [format [expr {$k eq "collections" ? "%d" : "%.1f"}] $v]
    }
    puts "| [join $cells { | }] |"
}
