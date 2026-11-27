# Bluetooth devices

Web Bluetooth gives a Bluetooth Low Energy device to the page. The root is `navigator.bluetooth`, and the grant is `web:bluetooth`.

```tcl
proc got {status dev} {
    if {$status eq "error"} {puts $dev; return}
    puts "device: [web::get $dev name]"
    web::call [web::get $dev gatt] connect -command connected
}
proc connected {status server} {
    if {$status eq "ok"} {web::call $server getPrimaryService battery_service -command service}
}
proc service {status svc} {
    if {$status eq "ok"} {web::call $svc getCharacteristic battery_level -command level}
}
proc level {status ch} {
    if {$status eq "ok"} {web::call $ch readValue -command {apply {{status v} {puts "battery: [scan $v %c]%"}}}}
}
set bt [web::root navigator.bluetooth]
dom on [dom query #connect] click {
    web::call $::bt requestDevice {filters {{services battery_service}}} -command got
}
```

A `DataView` is a byte array. A UUID such as `battery_service` is a string, and a number is the short UUID.
