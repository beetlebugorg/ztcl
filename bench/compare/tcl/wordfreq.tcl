# Counts the words of a text and writes the 20 most frequent.
# The work is in a proc: Tcl compiles the variables of a proc to slots.
proc main {argv} {
    set f [open [file join [lindex $argv 0] words.txt]]
    set text [string tolower [read $f]]
    close $f
    set words [regexp -all -inline {[a-z]+} $text]
    foreach w $words { dict incr counts $w }
    puts "tokens [llength $words] distinct [dict size $counts]"
    set sorted [lsort -stride 2 -index 1 -integer -decreasing [lsort -stride 2 -index 0 $counts]]
    foreach {w n} [lrange $sorted 0 39] { puts "$n $w" }
}
main $argv
