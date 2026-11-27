# HID devices

WebHID gives a human interface device, such as a keyboard with its own reports or a game controller, to the page. The root is `navigator.hid`, and the grant is `web:hid`.

```tcl
proc got {status devs} {
    if {$status eq "error"} {puts $devs; return}
    foreach dev $devs {
        puts [web::get $dev productName]
        web::call $dev open -command {apply {{status v} {}}}
    }
}
set hid [web::root navigator.hid]
dom on [dom query #connect] click {
    web::call $::hid requestDevice {filters {{vendorId 1452}}} -command got
}
```

`requestDevice` gives a list of handles. The arguments of `sendReport` are a report id and a byte array. The events `inputreport` of a device reach `web::on`, and `%target` is the device. The data of the report is not in the substitutions of `web::on` yet.
