# Gamepads

The Gamepad API gives the state of the game controllers. `getGamepads` is a method of `navigator`, and the events `gamepadconnected` and `gamepaddisconnected` are events of `window`. The grant is `web:gamepad`.

```tcl
proc poll {} {
    foreach pad [web::call [web::root navigator] getGamepads] {
        if {$pad eq ""} continue
        puts "[web::get $pad id]: [web::get $pad axes]"
    }
    after 100 poll
}
web::on [web::root window] gamepadconnected {puts "connected"; poll}
```

`getGamepads` gives a list with an empty element for each free slot. `axes` is a list of numbers, and `buttons` is a list of handles of `GamepadButton` with `pressed` and `value`. The API has no event for a change of an axis, so a script reads the state with `after`.
