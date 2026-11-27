# Builds one string of N formatted lines. Each line has 32 bytes.
# The work is in a proc: Tcl compiles the variables of a proc to slots.
proc main {argv} {
    set n [lindex $argv 0]
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        append out [format "%07d|%-12s|%10.3f\n" $i item[expr {$i % 1000}] [expr {$i * 1.5 / 7}]]
    }
    puts "[string length $out] [string range $out end-31 end-1]"
}
main $argv
