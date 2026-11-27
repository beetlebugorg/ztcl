# The heart-rate demo of web::bluetooth (bluetooth.html). It asks for a
# device with the Heart Rate service, turns on the notifications of the
# Heart Rate Measurement characteristic, and shows each rate.
set ::out [dom query #out]
set ::bpm [dom query #bpm]
set ::dev ""
proc show {text} {dom text $::out "[dom text $::out]$text\n"}
proc failed {status value} {
    if {$status eq "error"} {show $value}
    return [expr {$status eq "error"}]
}
proc found {status dev} {
    if {[failed $status $dev]} return
    set ::dev $dev
    show "device: [dict get [web::bluetooth::info $dev] name]"
    web::bluetooth::ondisconnect $dev {apply {{dev} {show "disconnected"}}}
    web::bluetooth::connect $dev -command connected
}
proc connected {status dev} {
    if {[failed $status $dev]} return
    web::bluetooth::service $dev heart_rate -command service
}
proc service {status svc} {
    if {[failed $status $svc]} return
    web::bluetooth::characteristic $svc heart_rate_measurement -command measurement
}
proc measurement {status ch} {
    if {[failed $status $ch]} return
    web::bluetooth::notify $ch beat -command {apply {{status v} {
        if {![failed $status $v]} {show "notifications on"}
    }}}
}
# A Heart Rate Measurement is a byte of flags and the rate: one byte, or
# two bytes (little endian) when bit 0 of the flags is 1.
proc beat {bytes} {
    binary scan $bytes cu flags
    if {$flags & 1} {
        binary scan $bytes x1su bpm
    } else {
        binary scan $bytes x1cu bpm
    }
    dom text $::bpm $bpm
}
dom on [dom query #go] click {
    dom text $::out ""
    web::bluetooth::request -services heart_rate -command found
}
dom on [dom query #stop] click {
    if {$::dev ne "" && [web::bluetooth::connected $::dev]} {web::bluetooth::disconnect $::dev}
}
