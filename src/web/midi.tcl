# The commands web::midi:: (#251): Web MIDI through the bridge of
# web::. `request` asks for the MIDI access of the page once, and then
# a port is its id, the key of the maps `inputs` and `outputs` of the
# MIDIAccess. A message is a list of numbers from 0 to 255, such as
# {144 60 100} for a note on. The host runs this script for allow:
# ["web:midi"].
#
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::web::midi {
    # The MIDIAccess, the handles of the ports by id, and the scripts of
    # listen and onchange.
    variable access ""
    variable port
    array set port {}
    variable listen
    array set listen {}
    variable change ""
}

proc ::web::midi::request {args} {
    set o [::web::lib::options "web::midi::request ?-sysex bool? ?-software bool? -command script" {sysex 0 software 0 command {}} $args]
    if {[dict get $o command] eq ""} {
        return -code error "wrong # args: should be \"web::midi::request ?-sysex bool? ?-software bool? -command script\""
    }
    set nav [::web::lib::root navigator web::midi "Web MIDI"]
    set opts [::list sysex [dict get $o sysex] software [dict get $o software]]
    if {[catch {web::call $nav requestMIDIAccess $opts -command [::list ::web::midi::Granted [dict get $o command]]} e]} {
        if {[string match "*is not a function*" $e]} {
            return -code error -errorcode {WEB UNSUPPORTED navigator.requestMIDIAccess} "web::midi: this browser has no Web MIDI"
        }
        return -code error $e
    }
    return
}

proc ::web::midi::Granted {script status value} {
    variable access
    if {$status eq "ok"} {
        set access $value
        web::on $access statechange [::list ::web::midi::Changed %event]
        set value ""
    }
    ::web::lib::reply $script $status $value
}

proc ::web::midi::Access {} {
    variable access
    if {$access eq ""} {
        return -code error "web::midi: no MIDI access: call web::midi::request first"
    }
    return $access
}

proc ::web::midi::inputs {} {
    return [web::call [web::get [Access] inputs] keys]
}

proc ::web::midi::outputs {} {
    return [web::call [web::get [Access] outputs] keys]
}

# The handle of the port `id`, an input or an output.
proc ::web::midi::Port {id {kind {}}} {
    variable port
    if {![::info exists port($id)]} {
        set a [Access]
        foreach m {inputs outputs} {
            set map [web::get $a $m]
            if {[web::call $map has $id]} {
                set port($id) [web::call $map get $id]
                break
            }
        }
        if {![::info exists port($id)]} {
            return -code error "web::midi: no port \"$id\""
        }
    }
    if {$kind ne "" && [web::get $port($id) type] ne $kind} {
        return -code error "web::midi: the port \"$id\" is not an $kind"
    }
    return $port($id)
}

proc ::web::midi::info {id} {
    set p [Port $id]
    set d [dict create id $id]
    foreach k {name manufacturer type state connection version} {
        dict set d $k [web::get $p $k]
    }
    return $d
}

proc ::web::midi::listen {id script} {
    variable listen
    set p [Port $id input]
    if {$script eq ""} {
        unset -nocomplain listen($id)
        web::off $p midimessage
        return
    }
    set listen($id) $script
    web::on $p midimessage [::list ::web::midi::Message $id %data]
    web::call $p open -command ::web::lib::fail
    return
}

proc ::web::midi::Message {id bytes} {
    variable listen
    if {![::info exists listen($id)]} return
    binary scan $bytes cu* nums
    ::web::lib::reply $listen($id) $id $nums
}

proc ::web::midi::send {id message args} {
    set o [::web::lib::options "web::midi::send output message ?-at ms?" {at {}} $args]
    set p [Port $id output]
    foreach b $message {
        if {![string is integer -strict $b] || $b < 0 || $b > 255} {
            return -code error "web::midi::send: expected a byte from 0 to 255 but got \"$b\""
        }
    }
    if {[dict get $o at] eq ""} {
        web::call $p send $message
    } else {
        web::call $p send $message [dict get $o at]
    }
    return
}

proc ::web::midi::onchange {script} {
    variable change
    Access
    set change $script
    return
}

proc ::web::midi::Changed {ev} {
    variable change
    variable port
    set p [web::get $ev port]
    web::release $ev
    if {$p eq ""} return
    set id [web::get $p id]
    set state [web::get $p state]
    if {![::info exists port($id)]} {set port($id) $p}
    ::web::lib::reply $change $id $state
}

proc ::web::midi::note {id key args} {
    set o [::web::lib::options "web::midi::note output key ?-velocity n? ?-channel n? ?-off bool?" {velocity 100 channel 1 off 0} $args]
    set ch [dict get $o channel]
    if {![string is integer -strict $ch] || $ch < 1 || $ch > 16} {
        return -code error "web::midi::note: expected a channel from 1 to 16 but got \"$ch\""
    }
    set v [dict get $o velocity]
    foreach {what n} [::list key $key velocity $v] {
        if {![string is integer -strict $n] || $n < 0 || $n > 127} {
            return -code error "web::midi::note: expected a $what from 0 to 127 but got \"$n\""
        }
    }
    if {[string is true -strict [dict get $o off]]} {
        send $id [::list [expr {0x80 + $ch - 1}] $key 0]
    } else {
        send $id [::list [expr {0x90 + $ch - 1}] $key $v]
    }
}
