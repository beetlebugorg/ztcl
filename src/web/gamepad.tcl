# The commands web::gamepad:: (#251): the Gamepad API through the bridge
# of web::. A pad is its index, the number of its slot in
# navigator.getGamepads(). `state` gives a dict of the axes and the
# buttons at the time of the call, and `poll` calls a script with the
# states at an interval with `after`. The states come from one call of
# the host (web::gamepad::Snapshot), with no handle, because a read of
# about 60 attributes through web::get cost about 0.5 ms. The events
# and `rumble` release the handles that they read. The host runs this
# script for allow: ["web:gamepad"].
#
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::web::gamepad {
    # The scripts of onconnect and ondisconnect, and the timer of poll.
    variable on
    array set on {}
    variable timer ""
    variable every 16
    variable script ""
}

# The state of each pad: one call of the host, with no handle.
proc ::web::gamepad::Snap {} {
    if {[catch {web::gamepad::Snapshot} pads]} {
        if {$pads eq "web: this browser has no navigator.getGamepads"} {
            return -code error -errorcode {WEB UNSUPPORTED navigator.getGamepads} "web::gamepad: this browser has no Gamepad API"
        }
        return -code error $pads
    }
    set out {}
    foreach p $pads {
        lassign $p index id mapping connected timestamp axes values pressed
        lappend out [dict create index $index id $id mapping $mapping connected $connected \
            timestamp $timestamp axes $axes buttons $values pressed $pressed]
    }
    return $out
}

# The indexes of the connected pads.
proc ::web::gamepad::list {} {
    set out {}
    foreach d [Snap] {
        if {[dict get $d connected]} {lappend out [dict get $d index]}
    }
    return $out
}

proc ::web::gamepad::state {{index {}}} {
    if {$index ne "" && (![string is integer -strict $index] || $index < 0)} {
        return -code error "expected a pad index but got \"$index\""
    }
    set pads [Snap]
    if {$index eq ""} {return $pads}
    foreach d $pads {
        if {[dict get $d index] == $index} {return $d}
    }
    return -code error "web::gamepad: no pad $index"
}

proc ::web::gamepad::poll {args} {
    variable timer
    variable every
    variable script
    set o [::web::lib::options "web::gamepad::poll ?-interval ms? -command script" {interval 16 command {}} $args]
    set ms [dict get $o interval]
    if {![string is integer -strict $ms] || $ms < 1} {
        return -code error "expected a positive integer interval but got \"$ms\""
    }
    if {[::info commands ::after] eq ""} {
        return -code error "web::gamepad::poll: the page has no event loop: grant \"event\""
    }
    after cancel $timer
    set timer ""
    set script [dict get $o command]
    set every $ms
    if {$script ne ""} {
        Snap
        set timer [after $every ::web::gamepad::Tick]
    }
    return
}

proc ::web::gamepad::Tick {} {
    variable timer
    variable every
    variable script
    set timer [after $every ::web::gamepad::Tick]
    ::web::lib::reply $script [state]
}

proc ::web::gamepad::onconnect {script} {
    On gamepadconnected connect $script
}

proc ::web::gamepad::ondisconnect {script} {
    On gamepaddisconnected disconnect $script
}

proc ::web::gamepad::On {event key script} {
    variable on
    set w [::web::lib::root window web::gamepad "the Gamepad API"]
    if {$script eq ""} {
        unset -nocomplain on($key)
        web::off $w $event
        return
    }
    set on($key) $script
    web::on $w $event [::list ::web::gamepad::Event $key %event]
    return
}

proc ::web::gamepad::Event {key ev} {
    variable on
    set pad [web::get $ev gamepad]
    web::release $ev
    set index [web::get $pad index]
    set id [web::get $pad id]
    web::release $pad
    if {[::info exists on($key)]} {::web::lib::reply $on($key) $index $id}
}

proc ::web::gamepad::rumble {index args} {
    set o [::web::lib::options "web::gamepad::rumble index ?-duration ms? ?-strong level? ?-weak level? ?-command script?" {duration 200 strong 1.0 weak 1.0 command {}} $args]
    set found ""
    foreach pad [web::call [::web::lib::root navigator web::gamepad "the Gamepad API"] getGamepads] {
        if {$pad eq ""} continue
        if {$found eq "" && [web::get $pad index] == $index} {
            set found [web::get $pad vibrationActuator]
        }
        web::release $pad
    }
    if {$found eq ""} {
        return -code error "web::gamepad: pad $index has no rumble"
    }
    set cb [dict get $o command]
    if {$cb eq ""} {set cb ::web::lib::fail}
    web::call $found playEffect dual-rumble [::list duration [dict get $o duration] \
        strongMagnitude [dict get $o strong] weakMagnitude [dict get $o weak]] -command $cb
    return
}
