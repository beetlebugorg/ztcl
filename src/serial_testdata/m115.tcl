# Sends M115 to a 3D printer on a serial port and keeps the lines of the
# reply in ::reply up to the line "ok". The same script runs against a
# PTY in the unit tests (src/serial_tests.zig) and against a fake Web
# Serial port in Node.js (tools/web-api.mjs). The caller waits for
# ::done: vwait in a native run, the events of the page in a browser.
proc m115 {chan} {
    set ::reply {}
    set ::done 0
    fconfigure $chan -mode 115200,n,8,1 -blocking 0 -buffering line
    fileevent $chan readable [list m115line $chan]
    puts $chan M115
}

proc m115line {chan} {
    while {[gets $chan line] >= 0} {
        set line [string trimright $line \r]
        lappend ::reply $line
        if {$line eq "ok"} {
            fileevent $chan readable {}
            set ::done 1
            return
        }
    }
    if {[eof $chan]} {
        fileevent $chan readable {}
        set ::done 2
    }
}
