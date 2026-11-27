# Tasks for the Web APIs from Tcl

Issue #251 has the goal: a Tcl script in the browser reaches the Web APIs (Web Serial, WebUSB, Web Bluetooth, WebHID, Web MIDI, Gamepad, and the others of the issue) through one bridge, and a script that talks to a serial port runs on the desktop and in a page. Do the tasks in the order of their numbers. One task is one branch and one review.

## The module

The bridge goes into `ztcl-host.wasm`, the module with the imports of [the host API tasks](../wasm-host-tasks/README.md) (#26). `ztcl.wasm` keeps no imports and has no bridge. The bridge uses the events of host task 04 (`runEvents`) for promises and for the events of an object, as `dom on` of [DOM task 03](../dom-tasks/README.md) does.

## The model

- An object of the page is a handle `webN` in a table of `web/ztcl.mjs`, as an element of `dom` is a handle `domN`. Tcl never gets a pointer and never runs JavaScript.
- A table that a generator makes from the Web IDL of the specs lists each interface, its attributes, its methods, the types of the arguments, and the group of the interface. The bridge calls only a member that the table has, and it converts each value by the type in the table. So a new API needs a new row of the table and no new code.
- Each group is a capability that the page grants: `allow: ["web:serial"]`, `"web:usb"`, `"web:bluetooth"`, `"web:hid"`, `"web:midi"`, `"web:gamepad"`, and so on. A member of a group that the page did not grant gives the error `web: the group "serial" is not allowed`. The permission prompt and the user-gesture rules of the browser apply on top of the grant: a call that needs a gesture works from a script of `dom on` for a click.
- A method that gives a promise has the option `-command script`. The result goes into the event queue, and the script runs from `runEvents` with two words appended: `ok` and the value, or `error` and the message. A call into wasm cannot wait for a promise.
- An error of the browser (a denied permission, no device) is a Tcl error with the name and the message of the `DOMException`, for example `web: NotFoundError: No port selected by the user.`

## The commands

    web::get obj attr                 the value of an attribute
    web::set obj attr value           sets an attribute
    web::call obj method ?arg ...? ?-command script?
    web::root name                    a root object of a granted group, for example navigator.serial
    web::on obj event script          runs script for each event of an EventTarget
    web::off obj event
    web::release obj                  ends the handle

A value is a string, a number, a boolean (0 or 1), a list for a sequence, a dict for a dictionary type, a handle for an interface type, and a byte array for a `BufferSource`.

## Tasks

| Task | Result |
|---|---|
| 01 | The handle table and the conversion of values in `web/ztcl.mjs`, the commands `web::root`, `web::get`, `web::set`, `web::call`, and `web::release` in `src/wasmweb.zig`, and a table written by hand with two interfaces of the group `serial`. A test in Node.js with a fake `navigator.serial` proves that the bridge is absent by default and in `ztcl.wasm`, that a member out of the table gives an error, and that a group that the page did not grant gives an error. |
| 02 | Promises: `-command` puts the result into the event queue, and `runEvents` runs the script. Each script has its own compute limit, as a callback of `dom on` has. Test: a fake promise that resolves and one that rejects. |
| 03 | `web::on` and `web::off` for an `EventTarget`, with `%type`, `%target`, and `%detail`. Test: a fake `connect` event of `navigator.serial`. |
| 04 | The generator `tools/webidl/`: it reads the Web IDL files of `tools/webidl/idl/` (a copy of the IDL blocks of each spec, with the URL and the date in a header) and writes `web/webidl-table.mjs`. `zig build test` checks that the file is the output of the generator, as for `tools/witgen`. The groups of the first table: `serial`, `usb`, `bluetooth`, `hid`, `midi`, and `gamepad`. |
| 05 | Native serial ports: `open /dev/ttyUSB0 r+` (Linux), `/dev/cu.*` (macOS), and `COM3` (Windows) with `fconfigure -mode baud,parity,data,stop`, `-handshake`, `-ttystatus`, and `-ttycontrol`, as in Tcl 8.6. The capability `file` covers them. Test: a pseudo-terminal on Linux and macOS. |
| 06 | Web Serial as a channel: `web::serial::request ?-filters list? -command script` gives a channel name to the script. `open` of that name with `r+` and `fconfigure -mode` open the port. The reads come from the `ReadableStream` of the port into a channel of `Interp.soft_chans`, so `gets`, `read`, `fileevent readable`, and `-blocking 0` work as for a native port. Test: a fake port in Node.js, and the same script against a pseudo-terminal in a native run. |
| 07 | Docs and demos: a page for each group in `docs/web/`, a support table by browser, a Web Serial demo that talks to a 3D printer (`M115`), and the npm types. |

fetch, WebSocket, and the File System Access API go behind the HTTP client (#27), the channels, and the capability `file` in later tasks of #251.

## Rules for each task

1. Follow the rules of [the host API tasks](../wasm-host-tasks/README.md#rules-for-each-task).
2. Each command of `web::` uses one compute unit, and a text or a list that it returns counts in the memory limit.
3. The Web IDL files are data of the specs. Copy only the IDL blocks, with the URL of the spec in the header of each file.

## State

| Task | State |
|---|---|
| 01 | done |
| 02 | done |
| 03 | done |
| 04 | done |
| 05 | done (#418) |
| 06 | done |
| 07 | done |
