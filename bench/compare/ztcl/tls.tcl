# Opens COUNT TLS 1.3 connections. Each one does a full handshake, reads
# 1 MiB to the end, and closes.
lassign $argv port cafile count
package require ztcl::tls
set f [open $cafile]
set ca [read $f]
close $f
set total 0
for {set i 0} {$i < $count} {incr i} {
    set s [ztcl::tls socket -servername localhost -cadata $ca 127.0.0.1 $port]
    fconfigure $s -translation binary
    incr total [string length [read $s]]
    close $s
}
puts $total
