# Module web::midi

The commands `web::midi::` give a script in the browser the MIDI ports of the computer through [Web MIDI](https://webaudio.github.io/web-midi-api/) and the bridge of [`web::`](web.md): keyboards, synthesizers, drum pads, and control surfaces. A port is its id, and a message is a list of numbers. [MIDI ports](../web/midi.md) is the guide, with a demo of keys.

> [!NOTE]
> `web::midi::` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
proc ready {status value} {
    if {$status eq "error"} {puts $value; return}
    foreach id [web::midi::inputs] {
        web::midi::listen $id {apply {{id message} {puts "$id: $message"}}}
    }
    set out [lindex [web::midi::outputs] 0]
    if {$out ne ""} {web::midi::note $out 60}
}
dom on [dom query #go] click {web::midi::request -command ready}
```

## Synopsis

```tcl
web::midi::request ?-sysex bool? ?-software bool? -command script
web::midi::inputs
web::midi::outputs
web::midi::info id
web::midi::listen input script
web::midi::send output message ?-at ms?
web::midi::note output key ?-velocity n? ?-channel n? ?-off bool?
web::midi::onchange script
```

## Commands

| Command | Result |
|---|---|
| `request ?-sysex bool? ?-software bool? -command script` | Asks for the MIDI access of the page (`requestMIDIAccess`). The script gets `ok` and an empty string, or `error` and the message. `-sysex 1` asks for the system exclusive messages too, and `-software 1` for the software synthesizers of the system. The other commands need a `request` that gave `ok`. |
| `inputs` | The ids of the input ports, such as a keyboard. |
| `outputs` | The ids of the output ports, such as a synthesizer. |
| `info id` | A dict of the port: `id name manufacturer type state connection version`. `type` is `input` or `output`, `state` is `connected` or `disconnected`, and `connection` is `open`, `closed`, or `pending`. |
| `listen input script` | Runs the script with the id of the port and the message appended for each message of the input. It opens the port (`open`). An empty script ends it. |
| `send output message ?-at ms?` | Sends the message, a list of numbers from 0 to 255, such as `{0x90 60 100}`. `-at` sends it at a time of `performance.now()` in milliseconds, and with no `-at` the browser sends it at once. |
| `note output key ?-velocity n? ?-channel n? ?-off bool?` | Sends a note on of the key (0 to 127, 60 is middle C) at the velocity (100 by default) on the channel (1 to 16, 1 by default). `-off 1` sends the note off. |
| `onchange script` | Runs the script with the id of the port and its state appended when a port connects or disconnects (`statechange`). An empty script ends it. |

## Messages

A message is a status byte and its data bytes:

| Status | Message | Data |
|---|---|---|
| `0x80` to `0x8F` | Note off of channel 1 to 16 | key, velocity |
| `0x90` to `0x9F` | Note on | key, velocity (0 is a note off) |
| `0xB0` to `0xBF` | Control change | control, value |
| `0xC0` to `0xCF` | Program change | program |
| `0xE0` to `0xEF` | Pitch bend | low 7 bits, high 7 bits |
| `0xF0` | System exclusive, only with `-sysex 1` | bytes up to `0xF7` |

Use `expr {$status & 0xf0}` for the kind of a message and `expr {($status & 0x0f) + 1}` for its channel.

## Errors

| Case | Error |
|---|---|
| A browser with no Web MIDI | `web::midi: this browser has no Web MIDI`, at the call, with the error code `WEB UNSUPPORTED navigator.requestMIDIAccess` |
| No grant `web:midi` | `invalid command name "web::midi::request"` |
| The user denies the access | `error {web: NotAllowedError: ...}` to the script of `request` |
| A command before `request` | `web::midi: no MIDI access: call web::midi::request first` |
| An unknown port | `web::midi: no port "ID"` |
| `listen` to an output, `send` to an input | `web::midi: the port "ID" is not an input` |
| A number out of range | `web::midi::send: expected a byte from 0 to 255 but got "300"` |

## Capability

The commands exist only in `ztcl-host.wasm` with `allow: ["web:midi"]`. They are Tcl procs (`src/web/midi.tcl`) on the commands of `web::`, and each message of an input reads its bytes with `%data` at the time of the event. The browser asks the user for the MIDI access, and Firefox asks for a site permission add-on first.
