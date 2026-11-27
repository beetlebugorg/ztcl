# Reads a CSV file of sales and writes the quantity and the revenue for
# each region and product. The core of Tcl has no CSV parser, so csvsplit
# splits a line with a regular expression. A field in quotes can have commas.
proc csvsplit {line} {
    if {[string first \" $line] < 0} { return [split $line ,] }
    set out {}
    foreach {- quoted plain} [regexp -all -inline {(?:^|,)(?:"([^"]*)"|([^,]*))} $line] {
        lappend out [expr {$quoted ne "" ? $quoted : $plain}]
    }
    return $out
}
# The work is in a proc: Tcl compiles the variables of a proc to slots.
proc main {argv} {
    set f [open [file join [lindex $argv 0] sales.csv]]
    gets $f
    set totalQty 0
    set totalRev 0.0
    while {[gets $f line] >= 0} {
        lassign [csvsplit $line] date region product qty price
        set rev [expr {$qty * $price}]
        set key $region|$product
        if {![info exists sumQty($key)]} {
            set sumQty($key) 0
            set sumRev($key) 0.0
        }
        incr sumQty($key) $qty
        set sumRev($key) [expr {$sumRev($key) + $rev}]
        incr totalQty $qty
        set totalRev [expr {$totalRev + $rev}]
    }
    close $f
    foreach key [lsort [array names sumQty]] {
        puts [format "%s|%d|%.2f" $key $sumQty($key) $sumRev($key)]
    }
    puts [format "TOTAL|%d|%.2f" $totalQty $totalRev]
}
main $argv
