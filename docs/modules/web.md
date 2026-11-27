# Module web

The commands `web::` give a script in the browser the Web APIs of the page through one bridge. The bridge calls a member of an API only when the table of the Web IDL of the specs lists it, and it converts each value by the type in the table.

> [!NOTE]
> `web::` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
proc ports {status value} {
    if {$status eq "error"} {puts $value; return}
    foreach port $value {puts [web::call $port getInfo]}
}
set serial [web::root navigator.serial]
web::call $serial getPorts -command ports
web::on $serial connect {puts "connect: [web::call %target getInfo]"}
```

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["web:serial"], web });
```

## Synopsis

```tcl
web::root name
web::get obj attr
web::set obj attr value
web::call obj method ?arg ...? ?-command script?
web::on obj event script
web::off obj event
web::release obj
```

| Command | Result |
|---|---|
| `web::root name` | The handle of a root object, for example `navigator.serial`. |
| `web::get obj attr` | The value of an attribute. |
| `web::set obj attr value` | Sets an attribute and gives an empty string. |
| `web::call obj method ?arg ...?` | Calls a method and gives its value. |
| `web::call obj method ?arg ...? -command script` | Calls a method that gives a promise, and gives an empty string. The script gets the result later. |
| `web::on obj event script` | Runs the script for each event of the type `event` of `obj`. A second `web::on` of the same event replaces the script. |
| `web::off obj event` | Ends the script of `web::on`. |
| `web::release obj` | Ends the handle and the scripts of `web::on` of the object. |

An object of the page is a handle `webN`. The same object gives the same handle. A handle stays until `web::release` or the end of the interpreter.

## Promises

A call into wasm cannot wait for a promise, so a method that gives a promise needs `-command script`. When the promise ends, the result goes into a queue. `runEvents` of the page runs the script at the global level with two words appended: `ok` and the value, or `error` and the message. A timer of `setTimeout` calls `runEvents` for each result, and `onEvents` gets the result of each run. An error of a bad argument comes at the time of the call.

Each script of a result has its own compute limit: the option `webComputeLimit` of `Interp.create` (1,000,000 compute units by default).

## Events

`web::on` needs an attribute `on<event>` of the type `EventHandler` in the table, for example `onconnect` of `Serial`. Each event goes into the queue of the results of the promises, and `runEvents` runs the script at the global level, with its own compute limit. Before the run, these names in the script get the values of the event, each one as one list element:

| Name | Value |
|---|---|
| `%type` | The type of the event, for example `connect`. |
| `%target` | The handle of the target of the event. For `connect` of `navigator.serial`, it is the port. |
| `%detail` | The `detail` of a `CustomEvent` when it is a string or a number, or an empty string. |
| `%%` | One `%`. |

## Values

| Web IDL type | Tcl value |
|---|---|
| `DOMString`, `USVString`, an enum | a string; an enum value must be one of the enum |
| `boolean` | 0 or 1 (an argument can be any Tcl boolean) |
| an integer type, `double` | a number; an integer argument must be in the range of its type |
| `sequence<T>` | a list |
| a dictionary | a dict of the members; a required member must be in the dict |
| an interface | a handle |
| `BufferSource`, `ArrayBuffer`, `Uint8Array` | a byte array: a string of the characters U+0000 to U+00FF |
| `undefined`, `null` | an empty string |

## Groups

Each interface of the table is in a group. The page grants a group with `allow`, for example `allow: ["web:serial"]`. A member of a group that the page did not grant gives the error `web: the group "serial" is not allowed`. The permission prompts and the user-gesture rules of the browser apply after the grant.

| Group | Spec | Roots and members of `navigator` |
|---|---|---|
| `serial` | [Web Serial API](https://serial.spec.whatwg.org/) | `navigator.serial` |
| `usb` | [WebUSB API](https://usb.spec.whatwg.org/) | `navigator.usb` |
| `bluetooth` | [Web Bluetooth](https://bluetooth.spec.whatwg.org/) | `navigator.bluetooth` |
| `hid` | [WebHID API](https://hid.spec.whatwg.org/) | `navigator.hid` |
| `midi` | [Web MIDI API](https://webaudio.github.io/web-midi-api/) | `navigator` with the method `requestMIDIAccess` |
| `gamepad` | [Gamepad](https://w3c.github.io/gamepad/) | `navigator` with the method `getGamepads`, and `window` with the events `gamepadconnected` and `gamepaddisconnected` |

The roots `navigator` and `window` have no group. Each of their members has the group of its spec, so `web::call [web::root navigator] getGamepads` needs `web:gamepad`.

The table is `web/webidl-table.mjs`. The generator `tools/webidl/` writes it from the IDL blocks of the specs in `tools/webidl/idl/`, one file for each group, with the URL of the spec in the header. `zig build webidl` writes the table again, and `zig build test` checks that the file is the output of the generator. A new API needs a new file of IDL and no new code. The generator leaves out constructors, constants, static members, iterables, and callbacks, so the commands cannot call them. A `maplike` gives `size`, `get`, `has`, `keys`, and `values`, where `keys` and `values` give a list.

## Errors

- A member out of the table: `web: the interface "Serial" has no method "eval"`.
- An error of the browser, such as a `DOMException`: `web: NotFoundError: No port selected by the user.`
- A method that gives a promise, with no `-command`: `web: the method "getPorts" gives a promise: use -command`.
- An attribute of an event handler, such as `onconnect`, gives an error for `web::get` and `web::set`.

## Capability

The commands exist only in `ztcl-host.wasm`, and only with a group of `web:` in `allow`. `ztcl.wasm` has no bridge. The page imports the bridge `web/ztcl-web.mjs`, which imports the table `web/webidl-table.mjs`, and gives it as the option `web`. `ztcl.mjs` does not import the bridge, so a page without a grant loads neither file. Each command costs one compute unit. The option `webRoot` of `Interp.create` sets the global object of the paths of `web::root` (`globalThis` by default).
