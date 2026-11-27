# The commands web::bluetooth:: (#251): Web Bluetooth through the
# bridge of web::. A device, a service, and a characteristic are handles
# of web::. Each command for a promise has the option -command, and the
# script gets `ok` and the value or `error` and the message. A
# notification runs the script of `notify` with the bytes of the value.
# The host runs this script for allow: ["web:bluetooth"].
#
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::web::bluetooth {
    # The scripts of `notify` and `ondisconnect` by handle.
    variable notify
    variable gone
    array set notify {}
    array set gone {}
}

# The full UUID of a 16-bit or 32-bit number, such as 0x180d. A name,
# such as heart_rate, and a full UUID stay as they are.
proc ::web::bluetooth::uuid {id} {
    if {[string is entier -strict $id]} {
        if {$id < 0 || $id > 0xffffffff} {
            return -code error "web::bluetooth: the UUID number $id is out of the range 0 to 0xffffffff"
        }
        return [format %08x-0000-1000-8000-00805f9b34fb $id]
    }
    return $id
}

proc ::web::bluetooth::Root {} {
    return [::web::lib::root navigator.bluetooth web::bluetooth "Web Bluetooth"]
}

proc ::web::bluetooth::request {args} {
    set usage "web::bluetooth::request ?-filters list? ?-services list? ?-name name? ?-prefix text? ?-optional list? ?-all bool? -command script"
    set o [::web::lib::options $usage {filters {} services {} name {} prefix {} optional {} all 0 command {}} $args]
    if {[dict get $o command] eq ""} {
        return -code error "wrong # args: should be \"$usage\""
    }
    set filters {}
    foreach f [dict get $o filters] {
        if {[dict exists $f services]} {
            dict set f services [lmap u [dict get $f services] {uuid $u}]
        }
        lappend filters $f
    }
    set f {}
    if {[dict get $o services] ne ""} {
        dict set f services [lmap u [dict get $o services] {uuid $u}]
    }
    if {[dict get $o name] ne ""} {dict set f name [dict get $o name]}
    if {[dict get $o prefix] ne ""} {dict set f namePrefix [dict get $o prefix]}
    if {$f ne ""} {lappend filters $f}
    set opts {}
    if {[string is true -strict [dict get $o all]]} {
        if {$filters ne ""} {
            return -code error "web::bluetooth::request: -all 1 goes with no filter"
        }
        dict set opts acceptAllDevices 1
    } elseif {$filters eq ""} {
        return -code error "web::bluetooth::request: give a filter (-filters, -services, -name, or -prefix) or -all 1"
    } else {
        dict set opts filters $filters
    }
    if {[dict get $o optional] ne ""} {
        dict set opts optionalServices [lmap u [dict get $o optional] {uuid $u}]
    }
    web::call [Root] requestDevice $opts -command [dict get $o command]
}

proc ::web::bluetooth::devices {args} {
    set o [::web::lib::options "web::bluetooth::devices -command script" {command {}} $args]
    web::call [Root] getDevices -command [dict get $o command]
}

proc ::web::bluetooth::available {args} {
    set o [::web::lib::options "web::bluetooth::available -command script" {command {}} $args]
    web::call [Root] getAvailability -command [dict get $o command]
}

proc ::web::bluetooth::Gatt {device} {
    set g [web::get $device gatt]
    if {$g eq ""} {
        return -code error "web::bluetooth: the device $device has no GATT server"
    }
    return $g
}

proc ::web::bluetooth::connect {device args} {
    set o [::web::lib::options "web::bluetooth::connect device -command script" {command {}} $args]
    web::call [Gatt $device] connect -command [list ::web::bluetooth::Connected $device [dict get $o command]]
}

proc ::web::bluetooth::Connected {device script status value} {
    if {$status eq "ok"} {set value $device}
    ::web::lib::reply $script $status $value
}

proc ::web::bluetooth::disconnect {device} {
    web::call [Gatt $device] disconnect
    return
}

proc ::web::bluetooth::connected {device} {
    set g [web::get $device gatt]
    if {$g eq ""} {return 0}
    return [web::get $g connected]
}

proc ::web::bluetooth::ondisconnect {device script} {
    variable gone
    if {$script eq ""} {
        unset -nocomplain gone($device)
        web::off $device gattserverdisconnected
        return
    }
    set gone($device) $script
    web::on $device gattserverdisconnected [list ::web::bluetooth::Gone $device]
    return
}

proc ::web::bluetooth::Gone {device} {
    variable gone
    if {[::info exists gone($device)]} {::web::lib::reply $gone($device) $device}
}

proc ::web::bluetooth::services {device args} {
    set usage "web::bluetooth::services device ?uuid? -command script"
    set id {}
    if {[llength $args] % 2} {
        set args [lassign $args id]
    }
    set o [::web::lib::options $usage {command {}} $args]
    set g [Gatt $device]
    if {$id eq ""} {
        web::call $g getPrimaryServices -command [dict get $o command]
    } else {
        web::call $g getPrimaryServices [uuid $id] -command [dict get $o command]
    }
}

proc ::web::bluetooth::service {device id args} {
    set o [::web::lib::options "web::bluetooth::service device uuid -command script" {command {}} $args]
    web::call [Gatt $device] getPrimaryService [uuid $id] -command [dict get $o command]
}

proc ::web::bluetooth::characteristics {service args} {
    set usage "web::bluetooth::characteristics service ?uuid? -command script"
    set id {}
    if {[llength $args] % 2} {
        set args [lassign $args id]
    }
    set o [::web::lib::options $usage {command {}} $args]
    if {$id eq ""} {
        web::call $service getCharacteristics -command [dict get $o command]
    } else {
        web::call $service getCharacteristics [uuid $id] -command [dict get $o command]
    }
}

proc ::web::bluetooth::characteristic {service id args} {
    set o [::web::lib::options "web::bluetooth::characteristic service uuid -command script" {command {}} $args]
    web::call $service getCharacteristic [uuid $id] -command [dict get $o command]
}

proc ::web::bluetooth::read {char args} {
    set o [::web::lib::options "web::bluetooth::read characteristic -command script" {command {}} $args]
    web::call $char readValue -command [dict get $o command]
}

proc ::web::bluetooth::write {char bytes args} {
    set o [::web::lib::options "web::bluetooth::write characteristic bytes ?-response bool? ?-command script?" {response {} command {}} $args]
    set r [dict get $o response]
    set m writeValue
    if {$r ne ""} {
        if {![string is boolean -strict $r]} {
            return -code error "expected boolean but got \"$r\""
        }
        set m [expr {$r ? "writeValueWithResponse" : "writeValueWithoutResponse"}]
    }
    set cb [dict get $o command]
    if {$cb eq ""} {set cb ::web::lib::fail}
    web::call $char $m $bytes -command [list ::web::bluetooth::Empty $cb]
}

# Gives the result of a promise of undefined as an empty value.
proc ::web::bluetooth::Empty {script status value} {
    if {$status eq "ok"} {set value ""}
    ::web::lib::reply $script $status $value
}

proc ::web::bluetooth::notify {char script args} {
    variable notify
    set o [::web::lib::options "web::bluetooth::notify characteristic script ?-command script?" {command {}} $args]
    set cb [dict get $o command]
    if {$cb eq ""} {set cb ::web::lib::fail}
    if {$script eq ""} {
        unset -nocomplain notify($char)
        web::off $char characteristicvaluechanged
        web::call $char stopNotifications -command [list ::web::bluetooth::Empty $cb]
        return
    }
    set notify($char) $script
    web::on $char characteristicvaluechanged [list ::web::bluetooth::Value $char %value]
    web::call $char startNotifications -command [list ::web::bluetooth::Empty $cb]
    return
}

proc ::web::bluetooth::Value {char bytes} {
    variable notify
    if {[::info exists notify($char)]} {::web::lib::reply $notify($char) $bytes}
}

# A dict of the facts of a device, a service, or a characteristic.
proc ::web::bluetooth::info {obj} {
    if {![catch {web::get $obj properties} props]} {
        set p {}
        foreach k {broadcast read writeWithoutResponse write notify indicate authenticatedSignedWrites reliableWrite writableAuxiliaries} {
            if {[web::get $props $k]} {lappend p $k}
        }
        return [dict create kind characteristic uuid [web::get $obj uuid] properties $p service [web::get $obj service]]
    }
    if {![catch {web::get $obj isPrimary} primary]} {
        return [dict create kind service uuid [web::get $obj uuid] primary $primary device [web::get $obj device]]
    }
    if {[catch {web::get $obj id} id]} {
        return -code error "web::bluetooth::info: $obj is not a device, a service, or a characteristic"
    }
    return [dict create kind device id $id name [web::get $obj name] connected [connected $obj]]
}

