# An HTTP/1.1 server with keep-alive on the event loop. Each request gets
# a small JSON body.
set body {{"ok":true,"n":42}}
# The channel turns each \n into \r\n.
set head "HTTP/1.1 200 OK\nContent-Type: application/json\nContent-Length: [string length $body]\n\n"
proc accept {sock addr port} {
    fconfigure $sock -blocking 0 -buffering full -translation {auto crlf}
    fileevent $sock readable [list request $sock]
}
proc request {sock} {
    global head body
    while {[gets $sock line] >= 0} {
        if {$line eq ""} {
            puts -nonewline $sock $head$body
            flush $sock
        }
    }
    if {[eof $sock]} { close $sock }
}
socket -server accept -myaddr 127.0.0.1 [lindex $argv 0]
puts ready
flush stdout
vwait forever
