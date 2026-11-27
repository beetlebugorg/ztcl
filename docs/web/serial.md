# Serial ports

Web Serial gives a serial port of the computer to the page. In ztcl a port is a channel, as a native serial port is, so one script works in the browser and in the `ztcl` program. [The page of `web::`](../modules/web.md#web-serial) has the details.

```tcl
proc start {status port} {
    if {$status eq "error"} {puts $port; return}
    set f [open $port r+]
    fconfigure $f -mode 115200,n,8,1 -blocking 0 -buffering line
    fileevent $f readable [list apply {{f} {
        while {[gets $f line] >= 0} {puts $line}
    }} $f]
    puts $f M115
}
dom on [dom query #connect] click {web::serial::request -command start}
```

Grant: `web:serial`. The demo [M115 to a 3D printer](https://beetlebug.org/ztcl/playground/serial.html) runs this script in the page with a port that you choose.

The same script with a native port:

```tcl
set f [open /dev/ttyUSB0 r+]   ;# COM3 on Windows, /dev/cu.usbserial-1410 on macOS
fconfigure $f -mode 115200,n,8,1
```

Web Serial has no mark or space parity, no 5 or 6 data bits, no `xonxoff`, and no `-ttystatus`. A read in the browser gives only the bytes that are there, as with `-blocking 0`.
