# Gamepads

The Gamepad API gives the state of the game controllers of the computer: the sticks, the buttons, and the triggers. In ztcl the commands [`web::gamepad::`](../modules/web-gamepad.md) give the state of each pad as a dict, a poll at an interval, and the events of a new pad.

Grant: `web:gamepad`, and `event` for the poll.

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["dom", "event", "web:gamepad"], web });
```

## Try it

The demo [move the ball](https://beetlebug.org/ztcl/playground/gamepad.html) moves a ball with the left stick and shows the buttons that are down. It works in each browser of the table below, and it starts only after a click.

## Read the state

The API has no event for a move of a stick, so a script reads the state at an interval. `poll` runs a script with the list of the states:

```tcl
proc frame {pads} {
    foreach pad $pads {
        lassign [dict get $pad axes] x y
        set fire [lindex [dict get $pad pressed] 0]
        puts "pad [dict get $pad index]: x $x y $y fire $fire"
    }
}
web::gamepad::poll -interval 16 -command frame
```

An interval of 16 ms is about 60 times a second. A stick at rest gives values near 0 and not exactly 0, so use a dead zone:

```tcl
if {abs($x) < 0.1} {set x 0}
```

`web::gamepad::poll -command {}` ends the poll. `web::gamepad::state 0` gives the state of one pad at once.

## New pads

A browser shows a pad to the page only after a press of a button on it, for privacy. `onconnect` runs a script at that time:

```tcl
web::gamepad::onconnect {apply {{index id} {puts "pad $index: $id"}}}
web::gamepad::ondisconnect {apply {{index id} {puts "pad $index went away"}}}
```

## Rumble

A pad with motors plays an effect:

```tcl
web::gamepad::rumble 0 -duration 300 -strong 1.0 -weak 0.5
```

## The standard layout

When `mapping` is `standard`, the indexes of the buttons and the axes are the same on each pad. The [reference](../modules/web-gamepad.md#the-state) has the list. A pad with an empty `mapping` has the order of its driver.

## Support by browser

The first version of each browser with the API, from the browser compatibility data of MDN (`@mdn/browser-compat-data` 8.1.11, 2026-11-26). "no" is no support in that data.

| API | Chrome | Edge | Firefox | Safari | Chrome on Android | Safari on iOS |
|---|---|---|---|---|---|---|
| `getGamepads` | 35 | 12 | 29 | 10.1 | 35 | 10.3 |
| `gamepadconnected` | 35 | 18 or earlier | 29 | 10.1 | 37 | 10.3 |
| Rumble (`playEffect`) | 68 | 15 | no | 16.4 | 68 | no |

Chrome 35 to 142, Firefox 29 to 88, and Safari 10.1 to 15.6 have the events only through `addEventListener`, which the bridge uses.

## Tests

`tools/web-groups.mjs` runs each command against a fake `navigator.getGamepads` in Node.js: the state, the poll, the events of a new pad, the rumble, the release of the handles, and a browser without the API. It runs the script of the demo against a fake pad. `tools/web-demos.mjs` runs the demo page in headless Chromium with a fake pad.
