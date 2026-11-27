# SPDX-License-Identifier: BSD-2-Clause
# Counts the words of a text and sorts the counts: split, string, dict incr, lsort -index.
# word frequency over generated text
proc gen {n} {
    set words {the quick brown fox jumps over lazy dog and then some other Words appear Here too with, punctuation. end}
    set out {}
    set s 12345
    for {set i 0} {$i < $n} {incr i} {
        set s [expr {($s * 1103515245 + 12345) & 0x7fffffff}]
        lappend out [lindex $words [expr {$s % [llength $words]}]]$[expr {$s % 97}]
        if {$i % 12 == 11} {lappend out "\n"}
    }
    return [join $out " "]
}
proc freq {text} {
    set d [dict create]
    foreach line [split $text "\n"] {
        foreach w [split [string tolower [string trim $line]] " "] {
            set w [string trim $w ".,"]
            if {$w eq ""} continue
            dict incr d $w
        }
    }
    set pairs {}
    dict for {k v} $d {lappend pairs [list $k $v]}
    set top [lrange [lsort -integer -decreasing -index 1 $pairs] 0 9]
    return $top
}
set t [gen 300000]
puts [string length $t]
puts [freq $t]
