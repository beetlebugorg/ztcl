# Parses a web server log with a regular expression and counts the
# requests by status and by path.
# The work is in a proc: Tcl compiles the variables of a proc to slots.
proc main {argv} {
    set f [open [file join [lindex $argv 0] access.log]]
    set re {^\S+ \S+ \S+ \[[^\]]+\] "\S+ ([^ ?"]+)[^"]*" (\d{3}) }
    while {[gets $f line] >= 0} {
        if {[regexp $re $line -> path status]} {
            dict incr byStatus $status
            dict incr byPath $path
        }
    }
    close $f
    foreach {s n} [lsort -stride 2 -index 0 $byStatus] { puts "$s $n" }
    set paths [lsort -stride 2 -index 0 $byPath]
    foreach {p n} [lrange [lsort -stride 2 -index 1 -integer -decreasing $paths] 0 39] { puts "$n $p" }
}
main $argv
