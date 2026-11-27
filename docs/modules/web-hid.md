# Module web::hid

The commands `web::hid::` give a script in the browser the HID devices of [WebHID](https://wicg.github.io/webhid/) through the bridge of [`web::`](web.md): game controllers with extra features, macro pads, sensors, and boards with a custom HID firmware. A device is a handle of `web::`, and a report is a byte array. [HID devices](../web/hid.md) is the guide.

> [!NOTE]
> `web::hid::` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
proc got {status devices} {
    if {$status eq "error" || $devices eq ""} {puts $devices; return}
    set dev [lindex $devices 0]
    web::hid::open $dev -command [list opened $dev]
}
proc opened {dev status value} {
    if {$status eq "error"} {puts $value; return}
    web::hid::listen $dev {apply {{dev id bytes} {puts "report $id: [binary encode hex $bytes]"}}}
}
dom on [dom query #go] click {web::hid::request -vendor 0x054c -command got}
```

## Synopsis

```tcl
web::hid::request ?-filters list? ?-vendor id? ?-product id? ?-page n? ?-usage n? -command script
web::hid::devices -command script
web::hid::info device
web::hid::open device ?-command script?
web::hid::close device ?-command script?
web::hid::listen device script
web::hid::send device report bytes ?-command script?
web::hid::feature device report ?bytes? ?-command script?
web::hid::onconnect script
web::hid::ondisconnect script
```

## Commands

| Command | Result |
|---|---|
| `request ...` | Shows the device chooser of the browser (`requestDevice`). The script gets `ok` and a list of devices: one HID device can have more than one entry. `-vendor`, `-product`, `-page` (the usage page), and `-usage` make one filter, and `-filters` is a list of dicts of `HIDDeviceFilter` (`vendorId productId usagePage usage`). |
| `devices -command script` | The devices that the user granted to the page before (`getDevices`), as a list. |
| `info device` | A dict: `vendor product name opened`. |
| `open device ?-command script?` | Opens the device. The script gets `ok` and an empty string. |
| `close device ?-command script?` | Closes the device. |
| `listen device script` | Runs the script with the device, the report id, and the bytes appended for each input report (`inputreport`). An empty script ends it. |
| `send device report bytes ?-command script?` | Sends an output report (`sendReport`). The report id is 0 for a device with no report ids. |
| `feature device report bytes ?-command script?` | Sends a feature report (`sendFeatureReport`). |
| `feature device report -command script` | Reads a feature report (`receiveFeatureReport`). The script gets `ok` and the bytes. |
| `onconnect script` | Runs the script with the device appended when a granted device connects. An empty script ends it. |
| `ondisconnect script` | Runs the script with the device appended when a device disconnects. |

A command with no `-command` gives an error of the browser to the error handler of the page (`onEvents` of `Interp.create`).

## Errors

| Case | Error |
|---|---|
| A browser with no WebHID | `web::hid: this browser has no WebHID`, with the error code `WEB UNSUPPORTED navigator.hid` |
| No grant `web:hid` | `invalid command name "web::hid::request"` |
| A report before `open` | `error {web: InvalidStateError: ...}` to the script |
| A `feature` read with no `-command` | `wrong # args: should be "web::hid::feature device report ?bytes? ?-command script?"` |

## Capability

The commands exist only in `ztcl-host.wasm` with `allow: ["web:hid"]`. They are Tcl procs (`src/web/hid.tcl`) on the commands of `web::`. Each input report reads its id and its bytes through `%event` at the time of the event and releases the handle of the event. HID reports are messages with an id, so they come to a script and not to a channel. The browser blocks some devices, such as keyboards and mice, from the page.
