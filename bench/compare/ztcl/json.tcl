# Parses a JSON file of records and writes it again with no spaces, with
# the built-in ztcl::json and a schema for the types.
package require ztcl::json
set schema {list {object {
    id int name string email string active bool score int
    tags {list string} address {object {city string zip string}}
}}}
set f [open [file join [lindex $argv 0] data.json]]
set data [ztcl::json parse [read $f]]
close $f
puts [ztcl::json encode -schema $schema $data]
