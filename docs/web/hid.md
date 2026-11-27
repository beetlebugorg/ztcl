# HID devices

WebHID gives the page the HID devices that the system gives no other API for: the extra features of game controllers, macro pads, sensors, and boards with a custom HID firmware. In ztcl the commands [`web::hid::`](../modules/web-hid.md) open a device, run a script for each input report, and send output and feature reports.

Grant: `web:hid`.

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["dom", "event", "web:hid"], web });
```

## Open a device and read its reports

```tcl
proc got {status devices} {
    if {$status eq "error" || $devices eq ""} {puts $devices; return}
    set dev [lindex $devices 0]
    puts [web::hid::info $dev]
    web::hid::open $dev -command [list opened $dev]
}
proc opened {dev status value} {
    if {$status eq "error"} {puts $value; return}
    web::hid::listen $dev report
}
proc report {dev id bytes} {
    binary scan $bytes cu* values
    puts "report $id: $values"
}
dom on [dom query #go] click {web::hid::request -page 0xff00 -command got}
```

`-page` and `-usage` pick devices by the usage of their top collection, such as `-page 1 -usage 5` for game pads. A vendor page, from `0xff00`, is the usual page of a custom firmware.

## Send reports

```tcl
# An output report with the id 1, such as the color of a light.
web::hid::send $dev 1 [binary format c3 {255 0 128}]
# Read the feature report 3.
web::hid::feature $dev 3 -command {apply {{status bytes} {puts [binary encode hex $bytes]}}}
```

## Support by browser

The first version of each browser with the API, from the browser compatibility data of MDN (`@mdn/browser-compat-data` 8.1.11, 2026-11-26). "no" is no support in that data.

| API | Chrome | Edge | Firefox | Safari | Chrome on Android | Safari on iOS |
|---|---|---|---|---|---|---|
| `requestDevice`, reports, events | 89 | 89 | no | no | no | no |

WebHID needs a secure context: HTTPS or `localhost`. A chooser opens only after a gesture of the user, such as a click.

## Tests

`tools/web-groups.mjs` runs the commands against a fake `navigator.hid` in Node.js: the filter, `open`, input reports, the release of the handles of the events, output and feature reports, a disconnection, and a browser without the API. No test uses a real device, so this page has no live demo.
