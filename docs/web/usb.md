# USB devices

WebUSB gives a USB device to the page. The root is `navigator.usb`, and the grant is `web:usb`.

```tcl
proc got {status dev} {
    if {$status eq "error"} {puts $dev; return}
    puts "[web::get $dev manufacturerName] [web::get $dev productName]"
    web::call $dev open -command [list opened $dev]
}
proc opened {dev status value} {
    if {$status eq "ok"} {puts "open: [web::get $dev opened]"}
}
set usb [web::root navigator.usb]
dom on [dom query #connect] click {
    web::call $::usb requestDevice {filters {{vendorId 9025}}} -command got
}
web::on $usb disconnect {puts "gone: %target"}
```

`transferIn` and `transferOut` give and take a byte array: `web::call $dev transferOut 1 "M115\n" -command done`. The result of `transferIn` is a handle of a `USBInTransferResult`: `web::get $r data` gives the bytes, and `web::get $r status` gives `ok`, `stall`, or `babble`.
