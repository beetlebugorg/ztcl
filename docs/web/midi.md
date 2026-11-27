# MIDI ports

Web MIDI gives the MIDI ports of the computer to the page. `requestMIDIAccess` is a method of `navigator`, and the grant is `web:midi`.

```tcl
proc access {status midi} {
    if {$status eq "error"} {puts $midi; return}
    foreach out [web::call [web::get $midi outputs] values] {
        puts "output: [web::get $out name]"
        # Note on, middle C, velocity 100; then note off.
        web::call $out send {144 60 100}
        web::call $out send {128 60 0}
    }
}
web::call [web::root navigator] requestMIDIAccess {sysex 0} -command access
```

The argument of `send` is a list of numbers (a `sequence<octet>`). `inputs` and `outputs` are maps: `values` and `keys` give lists, and the argument of `get` is a key. The events `midimessage` of an input reach `web::on`, and the data of the message is not in the substitutions yet.
