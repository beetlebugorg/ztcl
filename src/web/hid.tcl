# The commands web::hid:: (#251): WebHID through the bridge of web::. A
# device is a handle of web::. `listen` runs a script for each input
# report with the report id and the bytes, `send` sends an output
# report, and `feature` reads or writes a feature report. The host runs
# this script for allow: ["web:hid"].
#
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::web::hid {
    variable listen
    array set listen {}
    variable on
    array set on {}
}

proc ::web::hid::Root {} {
    return [::web::lib::root navigator.hid web::hid WebHID]
}

proc ::web::hid::request {args} {
    set usage "web::hid::request ?-filters list? ?-vendor id? ?-product id? ?-page n? ?-usage n? -command script"
    set o [::web::lib::options $usage {filters {} vendor {} product {} page {} usage {} command {}} $args]
    if {[dict get $o command] eq ""} {
        return -code error "wrong # args: should be \"$usage\""
    }
    set filters [dict get $o filters]
    set f {}
    foreach {k m} {vendor vendorId product productId page usagePage usage usage} {
        if {[dict get $o $k] ne ""} {dict set f $m [dict get $o $k]}
    }
    if {$f ne ""} {lappend filters $f}
    web::call [Root] requestDevice [::list filters $filters] -command [dict get $o command]
}

proc ::web::hid::devices {args} {
    set o [::web::lib::options "web::hid::devices -command script" {command {}} $args]
    web::call [Root] getDevices -command [dict get $o command]
}

proc ::web::hid::info {dev} {
    return [dict create vendor [web::get $dev vendorId] product [web::get $dev productId] \
        name [web::get $dev productName] opened [web::get $dev opened]]
}

proc ::web::hid::Empty {script status value} {
    if {$status eq "ok"} {set value ""}
    ::web::lib::reply $script $status $value
}

proc ::web::hid::Callback {o} {
    set cb [dict get $o command]
    if {$cb eq ""} {set cb ::web::lib::fail}
    return [::list ::web::hid::Empty $cb]
}

proc ::web::hid::open {dev args} {
    set o [::web::lib::options "web::hid::open device ?-command script?" {command {}} $args]
    web::call $dev open -command [Callback $o]
}

proc ::web::hid::close {dev args} {
    set o [::web::lib::options "web::hid::close device ?-command script?" {command {}} $args]
    web::call $dev close -command [Callback $o]
}

proc ::web::hid::send {dev report bytes args} {
    set o [::web::lib::options "web::hid::send device report bytes ?-command script?" {command {}} $args]
    web::call $dev sendReport $report $bytes -command [Callback $o]
}

proc ::web::hid::feature {dev report args} {
    set usage "web::hid::feature device report ?bytes? ?-command script?"
    set bytes {}
    set write 0
    if {[llength $args] % 2} {
        set args [lassign $args bytes]
        set write 1
    }
    set o [::web::lib::options $usage {command {}} $args]
    if {$write} {
        web::call $dev sendFeatureReport $report $bytes -command [Callback $o]
    } elseif {[dict get $o command] eq ""} {
        return -code error "wrong # args: should be \"$usage\""
    } else {
        web::call $dev receiveFeatureReport $report -command [dict get $o command]
    }
}

proc ::web::hid::listen {dev script} {
    variable listen
    if {$script eq ""} {
        unset -nocomplain listen($dev)
        web::off $dev inputreport
        return
    }
    set listen($dev) $script
    web::on $dev inputreport [::list ::web::hid::Report $dev %event]
    return
}

proc ::web::hid::Report {dev ev} {
    variable listen
    set id [web::get $ev reportId]
    set data [web::get $ev data]
    web::release $ev
    if {[::info exists listen($dev)]} {::web::lib::reply $listen($dev) $dev $id $data}
}

proc ::web::hid::onconnect {script} {On connect $script}
proc ::web::hid::ondisconnect {script} {On disconnect $script}

proc ::web::hid::On {event script} {
    variable on
    set h [Root]
    if {$script eq ""} {
        unset -nocomplain on($event)
        web::off $h $event
        return
    }
    set on($event) $script
    web::on $h $event [::list ::web::hid::Event $event %event]
    return
}

proc ::web::hid::Event {event ev} {
    variable on
    set dev [web::get $ev device]
    web::release $ev
    if {[::info exists on($event)]} {::web::lib::reply $on($event) $dev}
}
