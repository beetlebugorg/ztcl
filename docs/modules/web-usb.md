# Module web::usb

The commands `web::usb::` give a script in the browser the USB devices of [WebUSB](https://wicg.github.io/webusb/) through the bridge of [`web::`](web.md). A device is a handle of `web::`, and the bulk or interrupt endpoints of an interface are a channel, so `gets`, `read`, `puts`, and `fileevent` work on them. [USB devices](../web/usb.md) is the guide.

> [!NOTE]
> `web::usb::` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
proc got {status dev} {
    if {$status eq "error"} {puts $dev; return}
    web::usb::open $dev -interface 1 -in 1 -out 2 -command opened
}
proc opened {status chan} {
    if {$status eq "error"} {puts $chan; return}
    set f [open $chan r+]
    fconfigure $f -blocking 0 -buffering line
    fileevent $f readable [list apply {{f} {while {[gets $f line] >= 0} {puts $line}}} $f]
    puts $f "hello"
}
dom on [dom query #go] click {web::usb::request -vendor 0x2e8a -command got}
```

## Synopsis

```tcl
web::usb::request ?-filters list? ?-vendor id? ?-product id? ?-class code? -command script
web::usb::devices -command script
web::usb::info device
web::usb::open device ?-configuration n? ?-interface n? ?-in endpoint? ?-out endpoint? ?-packet bytes? -command script
web::usb::close device ?-command script?
web::usb::receive device endpoint length -command script
web::usb::transmit device endpoint bytes ?-command script?
web::usb::control device -direction in|out ?-type type? ?-recipient recipient? ?-request n? ?-value n? ?-index n? ?-length n? ?-data bytes? ?-command script?
web::usb::onconnect script
web::usb::ondisconnect script
```

## Commands

| Command | Result |
|---|---|
| `request ...` | Shows the device chooser of the browser (`requestDevice`). The script gets `ok` and the device. `-vendor`, `-product`, and `-class` make one filter, and `-filters` is a list of dicts of `USBDeviceFilter` (`vendorId productId classCode subclassCode protocolCode serialNumber`). |
| `devices -command script` | The devices that the user granted to the page before (`getDevices`), as a list. |
| `info device` | A dict: `vendor product manufacturer name serial class opened configuration`. |
| `open device ... -command script` | Opens the device, selects the configuration (1 by default) when it is not the current one, and claims the interface (0 by default). With `-in` or `-out`, the script gets `ok` and the name of a channel, such as `webusb1`; else `ok` and an empty string. |
| `close device ?-command script?` | Closes the device. |
| `receive device endpoint length -command script` | One transfer from the IN endpoint (`transferIn`). The script gets `ok` and the bytes. |
| `transmit device endpoint bytes ?-command script?` | One transfer to the OUT endpoint (`transferOut`). The script gets `ok` and the count of bytes that the device took. |
| `control device -direction in ...` | A control transfer (`controlTransferIn`). `-type` is `standard`, `class`, or `vendor` (the default), and `-recipient` is `device` (the default), `interface`, `endpoint`, or `other`. The script gets `ok` and up to `-length` bytes (64 by default). |
| `control device -direction out ...` | A control transfer with the bytes of `-data` (`controlTransferOut`). The script gets `ok` and the count. |
| `onconnect script` | Runs the script with the device appended when a granted device connects. An empty script ends it. |
| `ondisconnect script` | Runs the script with the device appended when a device disconnects. |

A command with no `-command` that sends data gives an error of the browser to the error handler of the page (`onEvents` of `Interp.create`).

## The channel

`open` of the name of `web::usb::open` with `r`, `w`, or `r+` gives a channel. `-in` and `-out` are the numbers of the endpoints (1 to 15, 0 for none), and `-packet` is the length of each `transferIn` (64 bytes by default, the size of a full-speed bulk packet). The bridge calls `transferIn` again after each result, and the bytes go into the channel as they come, as for [Web Serial](web.md#web-serial). A write goes to `transferOut` at each flush, in order. A stall of the IN endpoint clears with `clearHalt`, and another status other than `ok`, or a lost device, ends the input of the channel with the error. `close` of the channel ends the reads and keeps the device open. A USB channel has no `-mode`, `-handshake`, or `-ttycontrol`.

## Errors

| Case | Error |
|---|---|
| A browser with no WebUSB | `web::usb: this browser has no WebUSB`, with the error code `WEB UNSUPPORTED navigator.usb` |
| No grant `web:usb` | `invalid command name "web::usb::request"` |
| The user closes the chooser | `error {web: NotFoundError: ...}` to the script |
| A claimed interface, such as one of a driver of the system | `error {web: NetworkError: ...}` or `error {web: SecurityError: ...}` to the script of `open` |
| A status other than `ok` | `error {web::usb: the transfer gave the status "stall"}` to the script |
| `fconfigure -mode` of a USB channel | `web: a USB channel has no -mode, -handshake, or -ttycontrol` |

## Capability

The commands exist only in `ztcl-host.wasm` with `allow: ["web:usb"]`. They are Tcl procs (`src/web/usb.tcl`) on the commands of `web::`, and the channel is a stream of `src/wasmfiles.zig`, the same code as the channels of Web Serial. Chrome blocks the interfaces of some classes, such as HID and mass storage, and a device that has a driver of the system can need the driver to be off before `claimInterface` works.
