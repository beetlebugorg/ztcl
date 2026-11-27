# The commands web::usb:: (#251): WebUSB through the bridge of web::. A
# device is a handle of web::. `open` opens the device, selects the
# configuration, and claims the interface, and with -in or -out it gives
# a channel `webusbN` of the bulk or interrupt endpoints: a read gives the
# bytes of transferIn, and a write goes to transferOut. The host runs
# this script for allow: ["web:usb"].
#
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::web::usb {
    variable on
    array set on {}
}

proc ::web::usb::Root {} {
    return [::web::lib::root navigator.usb web::usb WebUSB]
}

proc ::web::usb::request {args} {
    set usage "web::usb::request ?-filters list? ?-vendor id? ?-product id? ?-class code? -command script"
    set o [::web::lib::options $usage {filters {} vendor {} product {} class {} command {}} $args]
    if {[dict get $o command] eq ""} {
        return -code error "wrong # args: should be \"$usage\""
    }
    set filters [dict get $o filters]
    set f {}
    foreach {k m} {vendor vendorId product productId class classCode} {
        if {[dict get $o $k] ne ""} {dict set f $m [dict get $o $k]}
    }
    if {$f ne ""} {lappend filters $f}
    web::call [Root] requestDevice [::list filters $filters] -command [dict get $o command]
}

proc ::web::usb::devices {args} {
    set o [::web::lib::options "web::usb::devices -command script" {command {}} $args]
    web::call [Root] getDevices -command [dict get $o command]
}

proc ::web::usb::info {dev} {
    set d [dict create vendor [web::get $dev vendorId] product [web::get $dev productId] \
        manufacturer [web::get $dev manufacturerName] name [web::get $dev productName] \
        serial [web::get $dev serialNumber] class [web::get $dev deviceClass] \
        opened [web::get $dev opened]]
    set c [web::get $dev configuration]
    dict set d configuration [expr {$c eq "" ? "" : [web::get $c configurationValue]}]
    return $d
}

proc ::web::usb::open {dev args} {
    set usage "web::usb::open device ?-configuration n? ?-interface n? ?-in endpoint? ?-out endpoint? ?-packet bytes? -command script"
    set o [::web::lib::options $usage {configuration 1 interface 0 in 0 out 0 packet 64 command {}} $args]
    if {[dict get $o command] eq ""} {
        return -code error "wrong # args: should be \"$usage\""
    }
    web::call $dev open -command [::list ::web::usb::Step $dev $o configure]
}

# The steps of `open`: configure, claim, then the channel.
proc ::web::usb::Step {dev o next status value} {
    set script [dict get $o command]
    if {$status eq "error"} {
        ::web::lib::reply $script error $value
        return
    }
    switch $next {
        configure {
            set c [web::get $dev configuration]
            if {$c ne "" && [web::get $c configurationValue] == [dict get $o configuration]} {
                Step $dev $o claim ok ""
            } else {
                web::call $dev selectConfiguration [dict get $o configuration] -command [::list ::web::usb::Step $dev $o claim]
            }
        }
        claim {
            web::call $dev claimInterface [dict get $o interface] -command [::list ::web::usb::Step $dev $o stream]
        }
        stream {
            if {[dict get $o in] == 0 && [dict get $o out] == 0} {
                ::web::lib::reply $script ok ""
            } elseif {[catch {web::usb::Stream $dev [dict get $o in] [dict get $o out] [dict get $o packet]} chan]} {
                ::web::lib::reply $script error $chan
            } else {
                ::web::lib::reply $script ok $chan
            }
        }
    }
}

proc ::web::usb::close {dev args} {
    set o [::web::lib::options "web::usb::close device ?-command script?" {command {}} $args]
    set cb [dict get $o command]
    if {$cb eq ""} {set cb ::web::lib::fail}
    web::call $dev close -command [::list ::web::usb::Empty $cb]
}

proc ::web::usb::Empty {script status value} {
    if {$status eq "ok"} {set value ""}
    ::web::lib::reply $script $status $value
}

# The result of a transfer: `ok` and the bytes (in) or the count (out).
proc ::web::usb::Result {script field status value} {
    if {$status eq "ok"} {
        set st [web::get $value status]
        set v [web::get $value $field]
        web::release $value
        if {$st ne "ok"} {
            set status error
            set v "web::usb: the transfer gave the status \"$st\""
        }
        set value $v
    }
    ::web::lib::reply $script $status $value
}

proc ::web::usb::receive {dev endpoint length args} {
    set o [::web::lib::options "web::usb::receive device endpoint length -command script" {command {}} $args]
    web::call $dev transferIn $endpoint $length -command [::list ::web::usb::Result [dict get $o command] data]
}

proc ::web::usb::transmit {dev endpoint bytes args} {
    set o [::web::lib::options "web::usb::transmit device endpoint bytes ?-command script?" {command {}} $args]
    set cb [dict get $o command]
    if {$cb eq ""} {set cb ::web::lib::fail}
    web::call $dev transferOut $endpoint $bytes -command [::list ::web::usb::Result $cb bytesWritten]
}

proc ::web::usb::control {dev args} {
    set usage "web::usb::control device -direction in|out -type standard|class|vendor -recipient device|interface|endpoint|other -request n -value n -index n ?-length n? ?-data bytes? -command script"
    set o [::web::lib::options $usage {direction in type vendor recipient device request 0 value 0 index 0 length 64 data {} command {}} $args]
    set setup [::list requestType [dict get $o type] recipient [dict get $o recipient] \
        request [dict get $o request] value [dict get $o value] index [dict get $o index]]
    set cb [dict get $o command]
    switch [dict get $o direction] {
        in {
            if {$cb eq ""} {return -code error "wrong # args: should be \"$usage\""}
            web::call $dev controlTransferIn $setup [dict get $o length] -command [::list ::web::usb::Result $cb data]
        }
        out {
            if {$cb eq ""} {set cb ::web::lib::fail}
            web::call $dev controlTransferOut $setup [dict get $o data] -command [::list ::web::usb::Result $cb bytesWritten]
        }
        default {
            return -code error "bad direction \"[dict get $o direction]\": must be in or out"
        }
    }
}

proc ::web::usb::onconnect {script} {On connect $script}
proc ::web::usb::ondisconnect {script} {On disconnect $script}

proc ::web::usb::On {event script} {
    variable on
    set u [Root]
    if {$script eq ""} {
        unset -nocomplain on($event)
        web::off $u $event
        return
    }
    set on($event) $script
    web::on $u $event [::list ::web::usb::Event $event %event]
    return
}

proc ::web::usb::Event {event ev} {
    variable on
    set dev [web::get $ev device]
    web::release $ev
    if {[::info exists on($event)]} {::web::lib::reply $on($event) $dev}
}
