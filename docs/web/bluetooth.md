# Bluetooth devices

Web Bluetooth gives the Bluetooth Low Energy devices near the computer to the page: heart-rate monitors, sensors, lights, and boards such as the micro:bit or an ESP32. In ztcl the commands [`web::bluetooth::`](../modules/web-bluetooth.md) give a device, its services, and its characteristics as handles, and each result goes to a `-command` script.

Grant: `web:bluetooth`.

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["dom", "event", "web:bluetooth"], web });
```

## Try it

The demo [a heart-rate monitor](https://beetlebug.org/ztcl/playground/bluetooth.html) connects to a chest strap or a watch with the Heart Rate service and shows the rate of each notification. It needs Chrome or Edge, and it asks for a device only after a click.

## The steps

A device has GATT services, and a service has characteristics. A characteristic has a value of bytes that a script reads, writes, or gets as notifications. A script does these steps, and each step gives its result to the next one:

1. `request` shows the chooser of the browser. The user picks a device.
2. `connect` connects to the device.
3. `service` gives a service of the device by its UUID.
4. `characteristic` gives a characteristic of the service by its UUID.
5. `read`, `write`, or `notify` uses the value.

```tcl
proc found {status dev} {
    if {$status eq "error"} {puts $dev; return}
    puts "device: [dict get [web::bluetooth::info $dev] name]"
    web::bluetooth::connect $dev -command connected
}
proc connected {status dev} {
    if {$status eq "error"} {puts $dev; return}
    web::bluetooth::service $dev heart_rate -command service
}
proc service {status svc} {
    if {$status eq "error"} {puts $svc; return}
    web::bluetooth::characteristic $svc heart_rate_measurement -command measurement
}
proc measurement {status ch} {
    if {$status eq "error"} {puts $ch; return}
    web::bluetooth::notify $ch beat
}
proc beat {bytes} {
    binary scan $bytes cu flags
    if {$flags & 1} {binary scan $bytes x1su bpm} else {binary scan $bytes x1cu bpm}
    puts "$bpm bpm"
}
dom on [dom query #go] click {
    web::bluetooth::request -services heart_rate -command found
}
```

The browser shows the chooser only after a gesture of the user, so the call of `request` goes in a script of `dom on` for a click. A call with no gesture gives a `SecurityError` to the script.

## Choose the device

`request` needs a filter. The chooser shows only the devices that match it, and the page gets only the services of the filter and of `-optional`:

```tcl
# Devices with the Heart Rate service, and the battery of the device.
web::bluetooth::request -services heart_rate -optional battery_service -command found
# A device by the start of its name.
web::bluetooth::request -prefix BBC -optional e95d6100-251d-470a-a062-fa1922dfa9a8 -command found
# Two filters: a device matches one or the other.
web::bluetooth::request -filters {{services heart_rate} {namePrefix Polar}} -command found
```

`-all 1` shows each device, and the page gets only the services of `-optional`.

## Read and write

A value is a byte array. Use `binary scan` to get numbers from it and `binary format` to make one:

```tcl
web::bluetooth::read $level -command {apply {{status v} {
    if {$status eq "ok"} {puts "battery: [scan $v %c]%"}
}}}
# The 16-bit value 500, little endian, with no response of the device.
web::bluetooth::write $speed [binary format su 500] -response 0
```

## Notifications

`notify` runs a script for each new value of a characteristic. An empty script turns the notifications off:

```tcl
web::bluetooth::notify $ch {apply {{bytes} {puts [binary encode hex $bytes]}}}
web::bluetooth::notify $ch {}
```

`ondisconnect` runs a script when the device goes out of range, turns off, or disconnects:

```tcl
web::bluetooth::ondisconnect $dev {apply {{dev} {puts "lost [dict get [web::bluetooth::info $dev] name]"}}}
```

## Errors

A browser with no Web Bluetooth gives the error `web::bluetooth: this browser has no Web Bluetooth` at the call, so a script can test for it with `catch`. An error of the browser after the call goes to the script as `error` and the message, such as `web: NotFoundError: ...` when the user closes the chooser. [The reference](../modules/web-bluetooth.md#errors) has the list.

## Support by browser

The first version of each browser with the API, from the browser compatibility data of MDN (`@mdn/browser-compat-data` 8.1.11, 2026-11-26). "no" is no support in that data.

| API | Chrome | Edge | Firefox | Safari | Chrome on Android | Safari on iOS |
|---|---|---|---|---|---|---|
| `requestDevice`, GATT, notifications | 70 (56 on macOS) | 79 | no | no | 56 | no |
| `writeValueWithResponse`, `writeValueWithoutResponse` | 85 | 85 | no | no | 85 | no |
| `getDevices` | 85, behind a flag | 85, behind a flag | no | no | 85, behind a flag | no |

The data says that Chrome and Edge on Linux have no Web Bluetooth by default. Web Bluetooth needs a secure context: HTTPS or `localhost`.

## Tests

`tools/web-groups.mjs` runs each command against a fake `navigator.bluetooth` in Node.js: the options of the chooser, the GATT steps, a read, the three kinds of write, the notifications, a disconnection, a closed chooser, and a browser without the API. It also runs the script of the demo against a fake heart-rate monitor. No test uses a real device.
