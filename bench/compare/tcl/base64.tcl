# Encodes 16 MB of bytes to base64 and decodes them again.
set f [open [file join [lindex $argv 0] bytes.bin] rb]
set data [read $f]
close $f
set enc [binary encode base64 $data]
set dec [binary decode base64 $enc]
puts "[string length $enc] [string range $enc 0 15] [string range $enc end-15 end] [expr {$dec eq $data ? "ok" : "bad"}]"
