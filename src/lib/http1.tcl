# The http package 1.0: the first HTTP client of Tcl, with the global
# commands http_get, http_config, and the others. src/tcllib.zig has
# this file. The behavior follows the tests of httpold.test of Tcl 8.6.
#
# A token is a global array http#N. http_get sends an HTTP/1.0
# request and reads the reply through the readable events of the
# socket: the status line, the headers, and the body to the end of the
# data or to Content-Length. The status is ok, eof, error, reset, or
# timeout. A -command runs when the reply is complete, and http_reset
# and a timeout do not run it.
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::http1 {}
array set ::http {
    -accept */*
    -proxyfilter httpProxyRequired
    -proxyhost {}
    -proxyport {}
    -useragent {Tcl http client package 1.0}
}
if {![info exists ::http(uid)]} {set ::http(uid) 0}

proc http_config {args} {
    global http
    set options [lsort [array names http -*]]
    if {[llength $args] == 0} {
        set out {}
        foreach o $options {lappend out $o $http($o)}
        return $out
    }
    if {[llength $args] == 1} {
        set o [lindex $args 0]
        if {$o ni $options} {
            return -code error "Unknown option $o, must be: [join $options {, }]"
        }
        return $http($o)
    }
    foreach {o v} $args {
        if {$o ni $options} {
            return -code error "Unknown option $o, must be: [join $options {, }]"
        }
    }
    foreach {o v} $args {set http($o) $v}
    return
}

proc httpProxyRequired {host} {
    global http
    if {$http(-proxyhost) ne "" && $http(-proxyport) ne ""} {
        return [list $http(-proxyhost) $http(-proxyport)]
    }
    return
}

proc http_reset {token {why reset}} {
    upvar #0 $token state
    if {![array exists state]} return
    set state(status) $why
    ::http1::Close $token
}

proc http_get {url args} {
    global http
    set options {-blocksize -channel -command -headers -progress -query -timeout -validate}
    set opts [dict create -blocksize 8192 -headers {} -timeout 0 -validate 0]
    foreach {flag value} $args {
        if {$flag ni $options} {
            return -code error "Unknown option $flag, can be: [join $options {, }]"
        }
        dict set opts $flag $value
    }
    if {[llength $args] % 2} {
        return -code error "Missing value for option [lindex $args end]"
    }
    if {![regexp -nocase {^(?:http://)?([^/:]+)(?::([0-9]+))?(/.*)?$} $url -> host port path]} {
        return -code error "Unsupported URL: $url"
    }
    if {$port eq ""} {set port 80}
    if {$path eq ""} {set path /}
    set token http#[incr http(uid)]
    upvar #0 $token state
    array unset state
    array set state $opts
    array set state {
        body {} currentsize 0 http {} meta {} state header status {}
        totalsize 0 type text/html
    }
    set state(url) $url
    set target [list $host $port]
    if {![catch {uplevel #0 [concat $http(-proxyfilter) [list $host]]} p] &&
            [llength $p] == 2} {
        set target $p
        set path http://$host:$port$path
    }
    if {[catch {socket {*}$target} sock]} {
        unset state
        return -code error $sock
    }
    set state(sock) $sock
    if {$state(-timeout) > 0} {
        set state(after) [after $state(-timeout) [list http_reset $token timeout]]
    }
    set method GET
    if {[info exists state(-query)]} {
        set method POST
    } elseif {$state(-validate)} {
        set method HEAD
    }
    fconfigure $sock -translation binary -buffering full
    set req "$method $path HTTP/1.0\r\n"
    append req "Accept: $http(-accept)\r\n"
    append req "Host: $host:$port\r\n"
    append req "User-Agent: $http(-useragent)\r\n"
    foreach {k v} $state(-headers) {
        append req "$k: [string map {\n "" \r ""} $v]\r\n"
    }
    if {$method eq "POST"} {
        append req "Content-Type: application/x-www-form-urlencoded\r\n"
        append req "Content-Length: [string length $state(-query)]\r\n\r\n"
        append req $state(-query)
    } else {
        append req "\r\n"
    }
    set state(method) $method
    if {[catch {
        puts -nonewline $sock $req
        flush $sock
    } err]} {
        catch {close $sock}
        unset state
        return -code error $err
    }
    fconfigure $sock -blocking 0
    fileevent $sock readable [list ::http1::Event $token]
    if {![info exists state(-command)]} {
        http_wait $token
    }
    return $token
}

proc http_wait {token} {
    upvar #0 $token state
    if {$state(status) eq ""} {
        vwait ${token}(status)
    }
    return $state(status)
}

proc http_data {token} {
    upvar #0 $token state
    return $state(body)
}

proc http_status {token} {
    upvar #0 $token state
    return $state(status)
}

proc http_code {token} {
    upvar #0 $token state
    return $state(http)
}

proc http_size {token} {
    upvar #0 $token state
    return $state(currentsize)
}

# The x-url-encoding of version 1.0: letters and digits stay, a space
# is +, a newline is %0d%0a, and each other character is %xx.
proc http_formatQuery {args} {
    set out {}
    foreach {k v} $args {
        lappend out [::http1::Map $k]=[::http1::Map $v]
    }
    return [join $out &]
}

proc ::http1::Map {string} {
    set out ""
    foreach c [split $string ""] {
        if {[string match {[a-zA-Z0-9]} $c]} {
            append out $c
        } elseif {$c eq " "} {
            append out +
        } elseif {$c eq "\n"} {
            append out %0d%0a
        } else {
            scan $c %c n
            append out %[format %.2x [expr {$n & 0xff}]]
        }
    }
    return $out
}

proc ::http1::Event {token} {
    upvar #0 $token state
    set sock $state(sock)
    if {$state(state) eq "header"} {
        while {[gets $sock line] >= 0} {
            set line [string trimright $line \r]
            if {$state(http) eq ""} {
                set state(http) $line
                continue
            }
            if {$line eq ""} {
                set state(state) body
                if {$state(method) eq "HEAD"} {
                    Finish $token ok
                    return
                }
                break
            }
            if {[regexp {^([^:]+):[ \t]*(.*)$} $line -> k v]} {
                set v [string trim $v]
                lappend state(meta) $k $v
                switch -- [string tolower $k] {
                    content-type {set state(type) $v}
                    content-length {set state(totalsize) $v}
                }
            }
        }
        if {$state(state) eq "header"} {
            if {[eof $sock]} {Finish $token eof}
            return
        }
    }
    if {[catch {read $sock $state(-blocksize)} block]} {
        set state(error) $block
        Finish $token error
        return
    }
    if {$block ne ""} {
        incr state(currentsize) [string length $block]
        if {[info exists state(-channel)]} {
            puts -nonewline $state(-channel) $block
        } else {
            append state(body) $block
        }
        if {[info exists state(-progress)]} {
            uplevel #0 [concat $state(-progress) \
                [list $token $state(totalsize) $state(currentsize)]]
        }
    }
    if {[eof $sock] || ($state(totalsize) > 0 && $state(currentsize) >= $state(totalsize))} {
        Finish $token ok
    }
}

proc ::http1::Close {token} {
    upvar #0 $token state
    catch {after cancel $state(after)}
    catch {fileevent $state(sock) readable {}}
    catch {close $state(sock)}
}

proc ::http1::Finish {token status} {
    upvar #0 $token state
    Close $token
    set state(status) $status
    if {[info exists state(-command)]} {
        catch {uplevel #0 [concat $state(-command) [list $token]]}
    }
}

package provide http 1.0
