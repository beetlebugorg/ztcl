# The gamepad demo of web::gamepad (gamepad.html). The left stick moves
# the ball in the box, button 0 (A on the standard layout) makes it big,
# and the page shows the buttons that are down.
set ::out [dom query #out]
set ::ball [dom query #ball]
set ::x 50.0
set ::y 50.0
proc show {text} {dom text $::out "[dom text $::out]$text\n"}
web::gamepad::onconnect {apply {{index id} {show "connected: pad $index, $id"}}}
web::gamepad::ondisconnect {apply {{index id} {show "disconnected: pad $index"}}}
proc frame {pads} {
    if {$pads eq ""} return
    set pad [lindex $pads 0]
    lassign [dict get $pad axes] ax ay
    # A dead zone, so a stick at rest does not move the ball.
    if {abs($ax) < 0.1} {set ax 0}
    if {abs($ay) < 0.1} {set ay 0}
    set ::x [expr {min(100.0, max(0.0, $::x + $ax * 2.0))}]
    set ::y [expr {min(100.0, max(0.0, $::y + $ay * 2.0))}]
    dom style $::ball left "$::x%"
    dom style $::ball top "$::y%"
    set down {}
    set i 0
    foreach p [dict get $pad pressed] {
        if {$p} {lappend down $i}
        incr i
    }
    dom style $::ball scale [expr {0 in $down ? 2 : 1}]
    dom text [dom query #buttons] [expr {$down eq "" ? "none" : $down}]
}
dom on [dom query #go] click {
    web::gamepad::poll -interval 16 -command frame
    dom text [dom query #go] "Running"
    show "press a button on the pad"
}
dom on [dom query #stop] click {
    web::gamepad::poll -command {}
    dom text [dom query #go] "Start"
}
