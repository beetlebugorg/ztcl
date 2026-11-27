# Parses a JSON file of records and writes it again with no spaces.
# tclsh has no JSON parser, so this uses tcllib json and json::write.
package require json
package require json::write
json::write indented 0
json::write aligned 0
# The work is in a proc: Tcl compiles the variables of a proc to slots.
proc main {argv} {
    set f [open [file join [lindex $argv 0] data.json]]
    set data [json::json2dict [read $f]]
    close $f
    set out {}
    foreach r $data {
        set tags {}
        foreach t [dict get $r tags] { lappend tags [json::write string $t] }
        set a [dict get $r address]
        lappend out [json::write object \
            id [dict get $r id] \
            name [json::write string [dict get $r name]] \
            email [json::write string [dict get $r email]] \
            active [dict get $r active] \
            score [dict get $r score] \
            tags [json::write array {*}$tags] \
            address [json::write object city [json::write string [dict get $a city]] zip [json::write string [dict get $a zip]]]]
    }
    puts [json::write array {*}$out]
}
main $argv
