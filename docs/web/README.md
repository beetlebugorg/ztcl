# Web APIs

A Tcl script in `ztcl-host.wasm` reaches the device APIs of the browser through the commands [`web::`](../modules/web.md). The bridge calls only the members of the table of the Web IDL of the specs, and the page grants each group with `allow`.

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["dom", "event", "web:serial"], web });
```

| Group | Guide | Commands | Grant |
|---|---|---|---|
| Web Serial | [Serial ports](serial.md) | [`web::serial::`](../modules/web.md#web-serial), channels | `web:serial` |
| WebUSB | [USB devices](usb.md) | `web::call` | `web:usb` |
| Web Bluetooth | [Bluetooth devices](bluetooth.md) | [`web::bluetooth::`](../modules/web-bluetooth.md) | `web:bluetooth` |
| WebHID | [HID devices](hid.md) | `web::call` | `web:hid` |
| Web MIDI | [MIDI ports](midi.md) | `web::call` | `web:midi` |
| Gamepad | [Gamepads](gamepad.md) | `web::call` | `web:gamepad` |

A group with its own commands has a Tcl wrapper in `ztcl-host.wasm`, and the grant of the group adds the commands. The other groups use the commands of `web::` directly.

The demos run in a page of their own, and each one starts only after a click:

- [M115 to a 3D printer](https://beetlebug.org/ztcl/playground/serial.html) sends a G-code to a printer on a serial port and shows the reply. It needs a browser with Web Serial.
- [A heart-rate monitor](https://beetlebug.org/ztcl/playground/bluetooth.html) shows the rate of a Bluetooth heart-rate monitor. It needs a browser with Web Bluetooth.

## Support by browser

The first version of each browser with the API, from the browser compatibility data of MDN (`@mdn/browser-compat-data` 8.1.11, 2026-11-26). "no" is no support in that data.

| API | Chrome | Edge | Firefox | Safari | Chrome on Android | Safari on iOS |
|---|---|---|---|---|---|---|
| Web Serial (`Serial`) | 89 | 89 | 151 | no | 148 | no |
| WebUSB (`USB`) | 61 | 79 | no | no | 61 | no |
| Web Bluetooth (`Bluetooth`) | 70 | 79 | no | no | 56 | no |
| WebHID (`HID`) | 89 | 89 | no | no | no | no |
| Web MIDI (`MIDIAccess`) | 43 | 79 | 108 | no | 43 | no |
| Gamepad (`Gamepad`) | 21 | 12 | 29 | 10.1 | 25 | 10.3 |

Each API except Gamepad needs a secure context (HTTPS or `localhost`). A chooser of a device opens only after a gesture of the user, so a script calls it from a script of `dom on` for a click.

## Tests

`tools/web-api.mjs` tests the bridge in Node.js with fake objects: the groups, the conversions, the promises, the events, `navigator.getGamepads`, and a Web Serial port. `tools/web-groups.mjs` tests the wrappers, such as `web::bluetooth::`, and the scripts of the demos with fake devices. The examples of the pages for USB, HID, and MIDI use only members of the table, and no test runs them against a device.
