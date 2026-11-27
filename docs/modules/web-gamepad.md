# Module web::gamepad

The commands `web::gamepad::` give a script in the browser the game controllers of the [Gamepad API](https://w3c.github.io/gamepad/) through the bridge of [`web::`](web.md). A pad is its index: the number of its slot in `navigator.getGamepads()`. [Gamepads](../web/gamepad.md) is the guide, with a demo that moves a ball with a stick.

> [!NOTE]
> `web::gamepad::` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
web::gamepad::onconnect {apply {{index id} {puts "pad $index: $id"}}}
web::gamepad::poll -interval 16 -command {apply {{pads} {
    foreach pad $pads {
        lassign [dict get $pad axes] x y
        puts "[dict get $pad index]: $x $y"
    }
}}}
```

## Synopsis

```tcl
web::gamepad::list
web::gamepad::state ?index?
web::gamepad::poll ?-interval ms? -command script
web::gamepad::onconnect script
web::gamepad::ondisconnect script
web::gamepad::rumble index ?-duration ms? ?-strong level? ?-weak level? ?-command script?
```

## Commands

| Command | Result |
|---|---|
| `list` | The indexes of the connected pads, in the order of their slots. |
| `state ?index?` | The state of the pad `index` as a dict, or with no index a list of the states of each pad. A free slot gives the error `web::gamepad: no pad N`. |
| `poll ?-interval ms? -command script` | Runs the script every `ms` milliseconds (16 by default) with the list of the states of each pad appended, as from `state`. A second `poll` replaces the first. An empty script ends the poll. |
| `onconnect script` | Runs the script with the index and the id of the pad appended when the browser shows a new pad (`gamepadconnected`). An empty script ends it. |
| `ondisconnect script` | Runs the script with the index and the id appended when a pad goes away (`gamepaddisconnected`). An empty script ends it. |
| `rumble index ?-duration ms? ?-strong level? ?-weak level? ?-command script?` | Plays the effect `dual-rumble` on the pad: 200 ms at the levels 1.0 by default, from 0.0 to 1.0. The script gets `ok` and `complete` or `preempted`, or `error` and the message. With no `-command`, an error goes to the error handler of the page. |

## The state

| Key | Value |
|---|---|
| `index` | The index of the pad. |
| `id` | The text of the browser for the pad, such as `Xbox 360 Controller (XInput STANDARD GAMEPAD)`. |
| `mapping` | `standard` when the buttons and the axes have the order of the standard layout, else an empty string. |
| `connected` | 1, or 0 after the pad went away. |
| `timestamp` | The time of the last change, in milliseconds of `performance.now()`. |
| `axes` | A list of numbers from -1.0 to 1.0. On the standard layout: left stick x, left stick y, right stick x, right stick y. Down and right are positive. |
| `buttons` | A list of the values of the buttons, from 0.0 to 1.0. A trigger has values between. |
| `pressed` | A list of 0 and 1, one for each button. |

The standard layout has these buttons: 0 to 3 are the right cluster (bottom, right, left, top: A, B, X, Y on an Xbox pad), 4 and 5 the bumpers, 6 and 7 the triggers, 8 and 9 select and start, 10 and 11 the stick presses, 12 to 15 the pad of arrows (up, down, left, right), and 16 the center button.

## Errors

| Case | Error |
|---|---|
| A browser with no Gamepad API | `web::gamepad: this browser has no Gamepad API`, with the error code `WEB UNSUPPORTED navigator.getGamepads` |
| No grant `web:gamepad` | `invalid command name "web::gamepad::list"` |
| `poll` with no grant `event` | `web::gamepad::poll: the page has no event loop: grant "event"` |
| A pad with no rumble | `web::gamepad: pad N has no rumble` |

## Capability

The commands exist only in `ztcl-host.wasm` with `allow: ["web:gamepad"]`, and `poll` needs `event` for its timer. They are Tcl procs (`src/web/gamepad.tcl`). `list`, `state`, and `poll` read each pad in one call of the host, with no handle, and that call costs one compute unit. The events and `rumble` use the commands of `web::` and release the handles that they read. A browser shows a pad to the page only after a press of a button on it.
