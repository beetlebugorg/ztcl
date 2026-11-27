# USB devices

WebUSB gives a USB device with no standard driver to the page: a board such as a Raspberry Pi Pico or an Arduino with a custom firmware, a measuring instrument, or a programmer. In ztcl the commands [`web::usb::`](../modules/web-usb.md) open a device and give its endpoints as a channel.

Grant: `web:usb`.

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["dom", "event", "web:usb"], web });
```

## Open a device

`request` shows the chooser, and `open` opens the device, selects the configuration, and claims the interface. With `-in` and `-out`, the result is a channel of the two endpoints:

```tcl
proc got {status dev} {
    if {$status eq "error"} {puts $dev; return}
    puts [web::usb::info $dev]
    web::usb::open $dev -interface 1 -in 1 -out 2 -command opened
}
proc opened {status chan} {
    if {$status eq "error"} {puts $chan; return}
    set ::f [open $chan r+]
    fconfigure $::f -blocking 0 -buffering line
    fileevent $::f readable {while {[gets $::f line] >= 0} {puts "device: $line"}}
    puts $::f "status"
}
dom on [dom query #go] click {web::usb::request -vendor 0x2e8a -command got}
```

The numbers of the interface and of the endpoints come from the descriptors of the device: see the docs of its firmware, or `lsusb -v` on Linux.

## Control transfers

Many devices take their commands as vendor control transfers:

```tcl
web::usb::control $dev -direction out -type vendor -recipient device -request 1 -value 0x0100 -index 0
web::usb::control $dev -direction in -type vendor -recipient device -request 2 -value 0 -index 0 -length 4 \
    -command {apply {{status bytes} {binary scan $bytes iu version; puts "version $version"}}}
```

## One transfer at a time

`receive` and `transmit` do one transfer, for a device with packets that are not a stream:

```tcl
web::usb::transmit $dev 2 [binary format c3 {1 2 3}]
web::usb::receive $dev 1 64 -command {apply {{status bytes} {puts [binary encode hex $bytes]}}}
```

## Support by browser

The first version of each browser with the API, from the browser compatibility data of MDN (`@mdn/browser-compat-data` 8.1.11, 2026-11-26). "no" is no support in that data.

| API | Chrome | Edge | Firefox | Safari | Chrome on Android | Safari on iOS |
|---|---|---|---|---|---|---|
| `requestDevice`, transfers, events | 61 | 79 | no | no | 61 | no |

WebUSB needs a secure context: HTTPS or `localhost`. A chooser opens only after a gesture of the user, such as a click.

## Tests

`tools/web-groups.mjs` runs the commands against a fake `navigator.usb` in Node.js: the filter, the steps of `open`, the channel with `gets` and `puts`, the control transfers, one transmit, a disconnection, and a browser without the API. No test uses a real device, so this page has no live demo.
