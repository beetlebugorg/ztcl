# Module web::bluetooth

The commands `web::bluetooth::` give a script in the browser the Bluetooth Low Energy devices of [Web Bluetooth](https://webbluetoothcg.github.io/web-bluetooth/) through the bridge of [`web::`](web.md). A device, a service, and a characteristic are handles of `web::`. [Bluetooth devices](../web/bluetooth.md) is the guide, with a demo for a heart-rate monitor.

> [!NOTE]
> `web::bluetooth::` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
proc found {status dev} {
    if {$status eq "error"} {puts $dev; return}
    web::bluetooth::connect $dev -command connected
}
proc connected {status dev} {
    if {$status eq "ok"} {web::bluetooth::service $dev battery_service -command service}
}
proc service {status svc} {
    if {$status eq "ok"} {web::bluetooth::characteristic $svc battery_level -command level}
}
proc level {status ch} {
    if {$status eq "ok"} {
        web::bluetooth::read $ch -command {apply {{status v} {puts "battery: [scan $v %c]%"}}}
    }
}
dom on [dom query #connect] click {
    web::bluetooth::request -services battery_service -command found
}
```

## Synopsis

```tcl
web::bluetooth::request ?-filters list? ?-services list? ?-name name? ?-prefix text? ?-optional list? ?-all bool? -command script
web::bluetooth::devices -command script
web::bluetooth::available -command script
web::bluetooth::connect device -command script
web::bluetooth::disconnect device
web::bluetooth::connected device
web::bluetooth::ondisconnect device script
web::bluetooth::services device ?uuid? -command script
web::bluetooth::service device uuid -command script
web::bluetooth::characteristics service ?uuid? -command script
web::bluetooth::characteristic service uuid -command script
web::bluetooth::read characteristic -command script
web::bluetooth::write characteristic bytes ?-response bool? ?-command script?
web::bluetooth::notify characteristic script ?-command script?
web::bluetooth::info handle
web::bluetooth::uuid id
```

## Callbacks

A command with `-command script` gives an empty string at once. When the browser has the result, the script runs at the global level with two words appended: `ok` and the value, or `error` and the message. This is the form of [`web::call -command`](web.md#promises), and each run has its own compute limit. An error in the arguments comes at the time of the call.

A script of `notify` and `ondisconnect` runs for each event with one word appended: the bytes of the value, or the device.

## Commands

| Command | Result |
|---|---|
| `request ...` | Shows the device chooser of the browser (`requestDevice`). The script gets `ok` and the device. The options are below. |
| `devices -command script` | The devices that the user granted to the page before (`getDevices`), as a list. Chrome has it behind a flag. |
| `available -command script` | 1 when the computer has a Bluetooth adapter, else 0 (`getAvailability`). |
| `connect device -command script` | Connects to the GATT server of the device. The script gets `ok` and the device. |
| `disconnect device` | Disconnects the GATT server and gives an empty string. |
| `connected device` | 1 when the GATT server is connected, else 0. |
| `ondisconnect device script` | Runs the script with the device appended at each disconnection (`gattserverdisconnected`). An empty script ends it. |
| `services device ?uuid? -command script` | The primary services of the device, as a list. With `uuid`, only the services of that UUID. |
| `service device uuid -command script` | The first primary service of the UUID. |
| `characteristics service ?uuid? -command script` | The characteristics of the service, as a list. |
| `characteristic service uuid -command script` | The first characteristic of the UUID. |
| `read characteristic -command script` | Reads the value. The script gets `ok` and the bytes. |
| `write characteristic bytes ?-response bool? ?-command script?` | Writes the bytes. `-response 1` waits for the response of the device (`writeValueWithResponse`), `-response 0` does not (`writeValueWithoutResponse`). With no `-response`, the browser picks by the properties of the characteristic. The script gets `ok` and an empty string. |
| `notify characteristic script ?-command script?` | Turns on the notifications (`startNotifications`) and runs the first script with the bytes of each new value. An empty script turns them off (`stopNotifications`). The `-command` script gets the result of the start or the stop. |
| `info handle` | A dict of the facts of a device (`kind device id name connected`), a service (`kind service uuid primary device`), or a characteristic (`kind characteristic uuid properties service`). `properties` is a list of the names of the true properties, such as `read notify`. |
| `uuid id` | The full UUID of a 16-bit or 32-bit number: `web::bluetooth::uuid 0x180d` gives `0000180d-0000-1000-8000-00805f9b34fb`. A name or a full UUID stays as it is. |

A command with no `-command` that writes or turns on the notifications sends an error of the browser to the error handler of the page (`onEvents` of `Interp.create`).

## UUIDs

A service or a characteristic is a UUID. A UUID argument has one of these forms:

- A name of the Bluetooth assigned numbers, such as `heart_rate`, `battery_service`, or `heart_rate_measurement`. The browser knows the names.
- A number such as `0x180d` or `6157`. The command changes it to the full UUID with `uuid`.
- A full UUID in lower case, such as `6e400001-b5a3-f393-e0a9-e50e24dcca9e`.

## Options of request

| Option | Value |
|---|---|
| `-services list` | A filter: devices that advertise each service of the list. |
| `-name name` | A filter: the device with this name. |
| `-prefix text` | A filter: devices with a name that starts with the text. |
| `-filters list` | A list of filters, each one a dict of `BluetoothLEScanFilterInit`: `services`, `name`, `namePrefix`, `manufacturerData`, and `serviceData`. A device that matches one filter goes in the chooser. |
| `-optional list` | More services for the page after the connection (`optionalServices`). A page can use only the services of the filters and of this list. |
| `-all bool` | `-all 1` shows each device near the computer (`acceptAllDevices`). It goes with no filter. |

`-services`, `-name`, and `-prefix` make one filter together, and it goes after the filters of `-filters`. A request needs a filter or `-all 1`.

## Errors

| Case | Error |
|---|---|
| A browser with no Web Bluetooth | `web::bluetooth: this browser has no Web Bluetooth`, at the call, with the error code `WEB UNSUPPORTED navigator.bluetooth` |
| No grant `web:bluetooth` | `invalid command name "web::bluetooth::request"` |
| The user closes the chooser | `error {web: NotFoundError: ...}` to the script |
| A request with no user gesture | `error {web: SecurityError: ...}` to the script |
| A service that the page did not ask for | `error {web: SecurityError: ...}` to the script |
| A lost device | `error {web: NetworkError: ...}` to the script |

The name of each error, such as `NotFoundError`, comes from the spec. The text after it comes from the browser and is different in each browser.

## Capability

The commands exist only in `ztcl-host.wasm` with `allow: ["web:bluetooth"]`. They are Tcl procs (`src/web/bluetooth.tcl`) on the commands of `web::`, so each one costs the compute units of its Tcl code and of its calls of `web::`. The browser asks the user for each device, and the chooser opens only after a gesture of the user, such as a click.
