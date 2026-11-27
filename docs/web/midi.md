# MIDI ports

Web MIDI gives the MIDI devices of the computer to the page: keyboards, synthesizers, drum pads, and control surfaces. In ztcl the commands [`web::midi::`](../modules/web-midi.md) give each port by its id and each message as a list of numbers.

Grant: `web:midi`.

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["dom", "event", "web:midi"], web });
```

## Try it

The demo [keys](https://beetlebug.org/ztcl/playground/midi.html) plays a note to the first MIDI output for each key that you press in the page, and it lights the key of each note from a MIDI keyboard. It asks for the MIDI access only after a click.

## Ask for the ports

`request` asks the user for the MIDI access. After an `ok`, `inputs` and `outputs` give the ids of the ports:

```tcl
proc ready {status value} {
    if {$status eq "error"} {puts $value; return}
    foreach id [web::midi::inputs] {
        puts "in: [dict get [web::midi::info $id] name]"
    }
    foreach id [web::midi::outputs] {
        puts "out: [dict get [web::midi::info $id] name]"
    }
}
dom on [dom query #go] click {web::midi::request -command ready}
```

## Listen to a keyboard

`listen` runs a script for each message of an input. A message is a list of numbers, such as `144 60 100` for a note on of middle C:

```tcl
proc heard {id message} {
    lassign $message status key velocity
    switch [expr {$status & 0xf0}] {
        144 {if {$velocity > 0} {puts "on $key"} else {puts "off $key"}}
        128 {puts "off $key"}
        176 {puts "control $key = $velocity"}
    }
}
foreach id [web::midi::inputs] {web::midi::listen $id heard}
```

## Play to a synthesizer

`note` sends a note on or a note off, and `send` sends any message:

```tcl
set synth [lindex [web::midi::outputs] 0]
web::midi::note $synth 60 -velocity 90
after 500 [list web::midi::note $synth 60 -off 1]
# Program change to program 5 on channel 1.
web::midi::send $synth {0xC0 5}
```

`-at` sends a message at a time of `performance.now()`, so the browser can play a sequence on time.

## Devices that come and go

`onchange` runs a script when a port connects or disconnects:

```tcl
web::midi::onchange {apply {{id state} {puts "$id is $state"}}}
```

## Support by browser

The first version of each browser with the API, from the browser compatibility data of MDN (`@mdn/browser-compat-data` 8.1.11, 2026-11-26). "no" is no support in that data.

| API | Chrome | Edge | Firefox | Safari | Chrome on Android | Safari on iOS |
|---|---|---|---|---|---|---|
| `requestMIDIAccess`, messages, `send` | 43 | 79 | 108 | no | 43 | no |
| `statechange` | 43 | 79 | no event | no | 43 | no |

The data says that Firefox asks for a site permission add-on before the access, and that its `statechange` event never fires. Web MIDI needs a secure context: HTTPS or `localhost`.

## Tests

`tools/web-groups.mjs` runs each command against a fake `navigator.requestMIDIAccess` in Node.js: the ports, the messages of an input, the bytes of `send` and `note`, a new port, a denied access, and a browser without the API. It runs the script of the demo against a fake keyboard and synthesizer. `tools/web-demos.mjs` runs the demo page in headless Chromium with the same fakes. No test uses a real device.
