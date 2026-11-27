# Renders an HTML table of N rows from a template with subst.
proc html {s} { string map {& &amp; < &lt; > &gt;} $s }
# The work is in a proc: Tcl compiles the variables of a proc to slots.
proc main {argv} {
    set n [lindex $argv 0]
    set row {<tr><td>$id</td><td>[html $name]</td><td>[format %.2f $price]</td></tr>}
    set out "<table>\n"
    for {set id 0} {$id < $n} {incr id} {
        set name "Part [expr {$id % 97}] & <Co>"
        set price [expr {($id % 1000) * 0.25}]
        append out [subst $row] \n
    }
    append out "</table>"
    puts $out
}
main $argv
