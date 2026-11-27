# The keys demo of web::midi (midi.html). A press of a key of the page
# sends a note to the first MIDI output, and each note of each MIDI input
# lights its key of the page.
set ::out [dom query #out]
set ::output ""
proc show {text} {dom text $::out "[dom text $::out]$text\n"}
proc ready {status value} {
    if {$status eq "error"} {show $value; return}
    set ins [web::midi::inputs]
    set outs [web::midi::outputs]
    show "inputs: [llength $ins], outputs: [llength $outs]"
    foreach id $ins {
        show "listen: [dict get [web::midi::info $id] name]"
        web::midi::listen $id heard
    }
    if {$outs ne ""} {
        set ::output [lindex $outs 0]
        show "play to: [dict get [web::midi::info $::output] name]"
    }
    web::midi::onchange {apply {{id state} {show "port $state: $id"}}}
}
# A note on is 0x90 to 0x9F with a velocity above 0. A note off is 0x80
# to 0x8F, or a note on with the velocity 0.
proc heard {id message} {
    lassign $message status key velocity
    set kind [expr {$status & 0xf0}]
    if {$kind != 0x80 && $kind != 0x90} return
    set key [dom query "#k$key"]
    if {$key eq ""} return
    if {$kind == 0x90 && $velocity > 0} {
        dom class $key add on
    } else {
        dom class $key remove on
    }
}
proc play {note on} {
    dom class [dom query "#k$note"] [expr {$on ? "add" : "remove"}] on
    if {$::output ne ""} {web::midi::note $::output $note -off [expr {!$on}]}
}
foreach key [dom queryAll .key] {
    set note [string range [dom attr $key id] 1 end]
    dom on $key pointerdown [list play $note 1]
    dom on $key pointerup [list play $note 0]
    dom on $key pointerleave [list play $note 0]
}
dom on [dom query #go] click {
    dom text $::out ""
    web::midi::request -command ready
}
