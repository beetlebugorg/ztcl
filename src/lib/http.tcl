# The http package 2.9.8: the client side of HTTP/1.1, as the manual
# page http.n of Tcl 8.6 describes it. src/tcllib.zig has this file.
#
# A request is a token, the name of an array in ::http. geturl checks
# the options and the URL, opens a socket (with -async when there is a
# -command), and writes the request when the socket is writable. The
# reply goes through the readable events of the socket: the status
# line, the header lines, and then the body, by Content-Length, by
# chunks, or to the end of the data. Finish closes or keeps the socket,
# sets the status, and calls -command. A geturl with no -command waits
# in the event loop for the status.
#
# A request with -keepalive 1 uses the one persistent socket of its
# host and port. When that socket is busy, the request waits in a
# queue and goes out after the reply before it. The requests on a
# socket do not overlap, so -pipeline has no effect on the order.
#
# The codings gzip, deflate, and compress need the zlib command. With
# no zlib command, the default Accept-Encoding is identity. The
# protocol https is registered at the start, with the TLS channels of
# the module ztcl::tls.
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::http {
    variable http
    if {![info exists http]} {
        array set http {
            -accept */*
            -pipeline 1
            -postfresh 0
            -proxyfilter http::ProxyRequired
            -proxyhost {}
            -proxyport {}
            -repost 0
            -urlencoding utf-8
            -zip 1
        }
        switch -- $::tcl_platform(platform),$::tcl_platform(os) {
            windows,* {set os "Windows; U; Windows NT 10.0"}
            unix,Darwin {set os "Macintosh; Intel Mac OS X 10_15"}
            default {set os "X11; $::tcl_platform(os) $::tcl_platform(machine)"}
        }
        set http(-useragent) "Mozilla/5.0 ($os) http/2.9.8 Tcl/[info patchlevel]"
        unset os
    }
    # The protocols: the default port and the command that opens the
    # channel.
    variable urlTypes
    array set urlTypes {http {80 ::socket} https {443 ::http::TlsSocket}}
    # The persistent sockets by host and port, the request that uses
    # each, and the requests that wait for each.
    variable socketMap
    variable socketBusy
    variable socketQueue
    array set socketMap {}
    array set socketBusy {}
    array set socketQueue {}
    variable registeredErrors
    array set registeredErrors {}
    variable defaultCharset iso8859-1
    # The Tcl encodings of Tcl 8.6. An encoding of this list that the
    # interpreter cannot load gives binary data in Finish.
    variable knownEncodings {
        ascii big5 cp1250 cp1251 cp1252 cp1253 cp1254 cp1255 cp1256 cp1257
        cp1258 cp437 cp737 cp775 cp850 cp852 cp855 cp857 cp860 cp861 cp862
        cp863 cp864 cp865 cp866 cp869 cp874 cp932 cp936 cp949 cp950
        dingbats ebcdic euc-cn euc-jp euc-kr gb12345 gb1988 gb2312
        gb2312-raw identity iso2022 iso2022-jp iso2022-kr iso8859-1
        iso8859-10 iso8859-11 iso8859-13 iso8859-14 iso8859-15 iso8859-16
        iso8859-2 iso8859-3 iso8859-4 iso8859-5 iso8859-6 iso8859-7
        iso8859-8 iso8859-9 jis0201 jis0208 jis0212 koi8-r koi8-u ksc5601
        maccenteuro maccroatian maccyrillic macdingbats macgreek
        maciceland macjapan macroman macromania macthai macturkish
        macukraine shiftjis symbol tis-620 unicode utf-8
    }
    namespace export config formatQuery geturl quoteString register \
        registerError reset unregister wait
}

# Sets the counter of tokens and the map of the bytes for
# formatQuery: each byte that is not unreserved in RFC 3986 gives %XX,
# and a newline gives %0D%0A.
proc http::init {} {
    variable http
    variable formMap
    if {![info exists http(uid)]} {set http(uid) 0}
    array unset formMap
    for {set i 0} {$i < 256} {incr i} {
        set c [format %c $i]
        if {![string match {[-a-zA-Z0-9._~]} $c]} {
            set formMap($c) %[format %.2X $i]
        }
    }
    set formMap(\n) %0D%0A
    return
}
http::init

proc http::Log {args} {}

proc http::config {args} {
    variable http
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
    if {[llength $args] % 2} {
        return -code error "Missing value for option [lindex $args end]"
    }
    foreach {o v} $args {
        if {$o in {-pipeline -postfresh -repost -zip} && ![string is boolean -strict $v]} {
            return -code error "Option $o must be a boolean, got \"$v\""
        }
    }
    foreach {o v} $args {set http($o) $v}
    return
}

# The default -proxyfilter: the proxy of config, when it has one.
proc http::ProxyRequired {host} {
    variable http
    if {$http(-proxyhost) ne "" && $http(-proxyport) ne ""} {
        return [list $http(-proxyhost) $http(-proxyport)]
    }
    return
}

# The default command of https: a TLS 1.3 channel of the module
# ztcl::tls. The handshake runs before the command returns, so -async
# has no effect, and -myaddr is not supported.
proc http::TlsSocket {args} {
    package require ztcl::tls
    set args [lsearch -all -inline -not -exact $args -async]
    if {[lindex $args 0] eq "-myaddr"} {set args [lrange $args 2 end]}
    lassign $args host port
    return [ztcl::tls socket -servername $host $host $port]
}

proc http::register {proto port command} {
    variable urlTypes
    set urlTypes([string tolower $proto]) [list $port $command]
}

proc http::unregister {proto} {
    variable urlTypes
    set lower [string tolower $proto]
    if {![info exists urlTypes($lower)]} {
        return -code error "unsupported url type \"$proto\""
    }
    set old $urlTypes($lower)
    unset urlTypes($lower)
    return $old
}

proc http::registerError {sock args} {
    variable registeredErrors
    if {[llength $args] > 1} {
        return -code error "wrong # args: should be \"http::registerError sock ?message?\""
    }
    if {[llength $args] == 1} {
        set registeredErrors($sock) [lindex $args 0]
    }
    if {[info exists registeredErrors($sock)]} {return $registeredErrors($sock)}
    return
}

# The x-url-encoding of a string with the -urlencoding of config.
proc http::mapReply {string} {
    variable http
    variable formMap
    set out ""
    if {$http(-urlencoding) ne ""} {
        set string [encoding convertto $http(-urlencoding) $string]
        foreach c [split $string ""] {
            if {[info exists formMap($c)]} {append out $formMap($c)} else {append out $c}
        }
        return $out
    }
    foreach c [split $string ""] {
        if {[string match {[-a-zA-Z0-9._~]} $c]} {
            append out $c
        } else {
            append out $formMap($c)
        }
    }
    return $out
}

proc http::quoteString {string} {
    return [mapReply $string]
}

proc http::formatQuery {args} {
    if {[llength $args] % 2} {
        return -code error "Incorrect number of arguments, must be an even number."
    }
    set out {}
    foreach {k v} $args {
        lappend out [mapReply $k]=[mapReply $v]
    }
    return [join $out &]
}

# The Tcl encoding of a charset name of HTTP, or binary.
proc http::CharsetToEncoding {charset} {
    variable knownEncodings
    set charset [string tolower [string trim $charset {"' }]]
    if {[regexp {^iso-?8859-?([0-9]+)$} $charset -> n]} {
        set enc iso8859-$n
    } elseif {[regexp {^iso-?2022-?(jp|kr)$} $charset -> n]} {
        set enc iso2022-$n
    } elseif {[regexp {^shift[-_]?jis$} $charset]} {
        set enc shiftjis
    } elseif {[regexp {^(?:windows|cp|ibm)-?([0-9]+)$} $charset -> n]} {
        set enc cp$n
    } elseif {$charset in {us-ascii ascii}} {
        set enc ascii
    } elseif {[regexp {^(?:iso-?)?lat(?:in)?-?([0-9]+)$} $charset -> n]} {
        switch -- $n {
            1 - 2 - 3 {set enc iso8859-$n}
            5 {set enc iso8859-9}
            default {return binary}
        }
    } else {
        set enc $charset
    }
    if {$enc in $knownEncodings || $enc in [encoding names]} {return $enc}
    return binary
}

# Gives the parts of a URL: proto host port (empty for the default)
# srvurl (the path and the query), and the user.
proc http::ParseUrl {url strict} {
    variable urlTypes
    set proto http
    if {[regexp {^([a-zA-Z][-+.a-zA-Z0-9]*)://(.*)$} $url -> proto rest]} {
    } elseif {[regexp {^//(.*)$} $url -> rest]} {
    } elseif {[string match /* $url]} {
        return -code error "Missing host part: $url"
    } elseif {[regexp {^[^/?#:]+:[0-9]*(?:[/?#]|$)} $url]} {
        set rest $url
    } elseif {[regexp {^[^/?#]*:} $url]} {
        return -code error "Unsupported URL: $url"
    } else {
        set rest $url
    }
    set proto [string tolower $proto]
    if {![info exists urlTypes($proto)]} {
        return -code error "Unsupported URL type \"$proto\""
    }
    # The fragment is for the client only.
    set i [string first # $rest]
    if {$i >= 0} {set rest [string range $rest 0 [expr {$i - 1}]]}
    regexp {^([^/?]*)(.*)$} $rest -> authority srvurl
    set user ""
    set i [string last @ $authority]
    if {$i >= 0} {
        set user [string range $authority 0 [expr {$i - 1}]]
        set authority [string range $authority [expr {$i + 1}] end]
    }
    set port ""
    if {[regexp {^\[([^\]]*)\](?::(.*))?$} $authority -> host port]} {
    } elseif {[regexp {^([^:]*)(?::(.*))?$} $authority -> host port]} {
    }
    if {$host eq ""} {
        return -code error "Missing host part: $url"
    }
    if {$port ne "" && (![string is digit -strict $port] || $port > 65535)} {
        return -code error "Invalid port number: $port"
    }
    if {$strict} {
        CheckPart $user {[-a-zA-Z0-9._~!$&'()*+,;=:%]} user
        CheckPart $srvurl {[-a-zA-Z0-9._~!$&'()*+,;=:@/?%]} path
    }
    if {![string match /* $srvurl]} {set srvurl /$srvurl}
    return [list $proto $host $port $srvurl $user]
}

# An error for a character outside the class, or a % that does not
# start a hex pair.
proc http::CheckPart {text class what} {
    foreach c [split $text ""] {
        if {![string match $class $c]} {
            return -code error "Illegal characters in URL $what"
        }
    }
    set i -1
    while {[set i [string first % $text [incr i]]] >= 0} {
        if {![regexp {^%[0-9a-fA-F]{2}} [string range $text $i end]]} {
            return -code error "Illegal encoding character usage\
                \"[string range $text $i [expr {$i + 2}]]\" in URL $what"
        }
    }
}

proc http::geturl {url args} {
    variable http
    variable urlTypes
    variable socketMap
    variable socketBusy
    variable socketQueue
    set options {-binary -blocksize -channel -command -handler -headers
        -keepalive -method -myaddr -progress -protocol -query
        -queryblocksize -querychannel -queryprogress -strict -timeout
        -type -validate}
    # The options are checked before a token exists.
    set opts [dict create -binary 0 -blocksize 8192 -headers {} \
        -keepalive 0 -protocol 1.1 -queryblocksize 8192 -strict 1 \
        -timeout 0 -type application/x-www-form-urlencoded -validate 0]
    foreach {flag value} $args {
        if {$flag ni $options} {
            return -code error "Unknown option $flag, can be: [join $options {, }]"
        }
        switch -- $flag {
            -binary - -keepalive - -strict - -validate {
                if {![string is boolean -strict $value]} {
                    return -code error "Bad value for $flag ($value), must be boolean"
                }
            }
            -blocksize - -queryblocksize - -timeout {
                if {![string is integer -strict $value] || $value < 0} {
                    return -code error "Bad value for $flag ($value), must be integer"
                }
            }
            -headers {
                if {[catch {llength $value}]} {
                    return -code error "Bad value for -headers ($value), must be list"
                }
                if {[llength $value] % 2} {
                    return -code error "Bad value for -headers ($value),\
                        number of list elements must be even"
                }
            }
        }
        dict set opts $flag $value
    }
    if {[llength $args] % 2} {
        return -code error "Missing value for option [lindex $args end]"
    }
    lassign [ParseUrl $url [dict get $opts -strict]] proto host port srvurl
    lassign $urlTypes($proto) defport defcmd
    if {$port eq ""} {set port $defport; set hostport $host} else {set hostport $host:$port}
    if {[string first : $host] >= 0} {
        set hostport "\[$host\][expr {$port == $defport ? "" : ":$port"}]"
    }

    if {![info exists http(uid)]} {set http(uid) 0}
    set token [namespace current]::[incr http(uid)]
    variable $token
    upvar 0 $token state
    array unset state
    array set state $opts
    array set state {
        binary 0 body {} charset {} coding {} connection close
        currentsize 0 http {} meta {} queryoffset 0 querylength 0
        reusing 0 sock {} state connecting status {} totalsize 0
        transfer {} type text/html
    }
    set state(url) $url
    set state(charset) $::http::defaultCharset

    # The method and the body of the request.
    if {[info exists state(-querychannel)]} {
        fconfigure $state(-querychannel) -translation binary
        set state(method) POST
    } elseif {[info exists state(-query)] && $state(-query) ne ""} {
        set q $state(-query)
        if {![regexp {^[\x00-\xff]*$} $q]} {set q [encoding convertto utf-8 $q]}
        set state(-query) $q
        set state(querylength) [string length $q]
        set state(method) POST
    } elseif {$state(-validate)} {
        set state(method) HEAD
    } else {
        set state(method) GET
    }
    if {[info exists state(-method)] && $state(-method) ne ""} {
        set state(method) $state(-method)
    }
    # A -handler gets the body as the server sends it, so the request
    # is HTTP/1.0 and asks for no coding.
    if {[info exists state(-handler)]} {
        set state(-protocol) 1.0
        set state(-keepalive) 0
    }
    if {$state(method) eq "POST" && $http(-postfresh)} {
        set state(-keepalive) 0
    }
    foreach {k v} $state(-headers) {
        if {[string equal -nocase $k Upgrade]} {set state(-keepalive) 0}
    }
    if {$state(-protocol) eq "1.0"} {set state(-keepalive) 0}

    # The proxy, from the filter of config.
    set target $host
    set tport $port
    set state(proxy) 0
    if {![catch {uplevel #0 [concat $http(-proxyfilter) [list $host]]} p] &&
            [llength $p] == 2} {
        lassign $p target tport
        set state(proxy) 1
        set srvurl $proto://$hostport$srvurl
    }
    set state(srvurl) $srvurl
    set state(hostport) $hostport
    set state(key) $target:$tport
    set state(target) [list $target $tport]
    set state(defcmd) $defcmd

    if {$state(-timeout) > 0} {
        set state(after) [after $state(-timeout) [list http::reset $token timeout]]
    }

    set key $state(key)
    if {$state(-keepalive) && [info exists socketMap($key)]} {
        if {$socketBusy($key) ne ""} {
            # The socket is busy: the request waits for it.
            lappend socketQueue($key) $token
        } else {
            set state(sock) $socketMap($key)
            set state(reusing) 1
            set socketBusy($key) $token
            fileevent $state(sock) readable {}
            Connected $token
        }
    } elseif {[catch {OpenSocket $token} err opts]} {
        catch {after cancel $state(after)}
        unset state
        return -options $opts $err
    }
    if {![info exists state(-command)]} {
        wait $token
        if {$state(status) eq "error"} {
            set err [lindex $state(error) 0]
            cleanup $token
            return -code error $err
        }
    }
    return $token
}

# Opens a new socket for the request. With -command the socket is
# -async, and the writable event gives the end of the connection.
proc http::OpenSocket {token} {
    variable $token
    upvar 0 $token state
    variable socketMap
    variable socketBusy
    variable socketQueue
    set cmd $state(defcmd)
    if {[info exists state(-myaddr)]} {lappend cmd -myaddr $state(-myaddr)}
    if {[info exists state(-command)]} {lappend cmd -async}
    set sock [uplevel #0 [concat $cmd $state(target)]]
    set state(sock) $sock
    set state(reusing) 0
    if {$state(-keepalive)} {
        set key $state(key)
        if {[info exists socketMap($key)]} {
            catch {close $socketMap($key)}
        }
        set socketMap($key) $sock
        set socketBusy($key) $token
        if {![info exists socketQueue($key)]} {set socketQueue($key) {}}
    }
    if {[info exists state(-command)]} {
        fileevent $sock writable [list http::Connected $token]
    } else {
        Connected $token
    }
}

# Writes the request line and the headers, and then the body.
proc http::Connected {token} {
    variable http
    variable $token
    upvar 0 $token state
    variable socketBusy
    if {![array exists state] || $state(status) ne ""} {
        # A request of the queue that ended before its turn.
        foreach key [array names socketBusy] {
            if {$socketBusy($key) eq $token} {set socketBusy($key) ""}
        }
        return
    }
    set sock $state(sock)
    fileevent $sock writable {}
    if {[catch {fconfigure $sock -error} err] == 0 && $err ne ""} {
        Finish $token "connect failed $err"
        return
    }
    set state(state) header
    fconfigure $sock -translation binary -blocking 0 -buffering full
    set given {}
    foreach {k v} $state(-headers) {lappend given [string tolower $k]}
    set req "$state(method) $state(srvurl) HTTP/$state(-protocol)\r\n"
    append req "Host: $state(hostport)\r\n"
    if {"user-agent" ni $given} {append req "User-Agent: $http(-useragent)\r\n"}
    if {"connection" ni $given} {
        append req "Connection: [expr {$state(-keepalive) ? "keep-alive" : "close"}]\r\n"
    }
    foreach {k v} $state(-headers) {
        set v [string map {\n "" \r ""} $v]
        if {[string tolower $k] eq "content-length"} {set state(querylength) $v}
        append req "$k: $v\r\n"
    }
    if {"accept" ni $given} {append req "Accept: $http(-accept)\r\n"}
    if {"accept-encoding" ni $given && ![info exists state(-handler)]} {
        if {$http(-zip) && [llength [info commands ::zlib]]} {
            append req "Accept-Encoding: gzip,deflate,compress\r\n"
        } else {
            append req "Accept-Encoding: identity\r\n"
        }
    }
    set post [expr {[info exists state(-querychannel)] || $state(querylength) > 0}]
    if {$post} {
        if {"content-type" ni $given} {append req "Content-Type: $state(-type)\r\n"}
        if {"content-length" ni $given} {
            if {[info exists state(-querychannel)]} {
                set qc $state(-querychannel)
                set start [tell $qc]
                if {$start < 0 || [catch {seek $qc 0 end; set end [tell $qc]; seek $qc $start}]} {
                    Finish $token "Unable to determine size of querychannel data"
                    return
                }
                set state(querylength) [expr {$end - $start}]
            }
            append req "Content-Length: $state(querylength)\r\n"
        }
    }
    append req "\r\n"
    if {[catch {
        puts -nonewline $sock [encoding convertto iso8859-1 $req]
        flush $sock
    } err]} {
        Finish $token $err
        return
    }
    fileevent $sock readable [list http::Event $token]
    if {$post} {
        fileevent $sock writable [list http::Write $token]
    }
}

# Writes one block of the body of a POST.
proc http::Write {token} {
    variable $token
    upvar 0 $token state
    set sock $state(sock)
    set n $state(-queryblocksize)
    if {[catch {
        if {[info exists state(-querychannel)]} {
            set left [expr {$state(querylength) - $state(queryoffset)}]
            set block [read $state(-querychannel) [expr {min($n, $left)}]]
            if {$block eq ""} {set state(querylength) $state(queryoffset)}
        } else {
            set block [string range $state(-query) $state(queryoffset) \
                [expr {$state(queryoffset) + $n - 1}]]
        }
        puts -nonewline $sock $block
        flush $sock
        incr state(queryoffset) [string length $block]
    } err]} {
        # The server may answer before it reads the whole body.
        set state(posterror) $err
        fileevent $sock writable {}
        return
    }
    if {$state(queryoffset) >= $state(querylength)} {
        fileevent $sock writable {}
    }
    if {[info exists state(-queryprogress)] && $state(-queryprogress) ne ""} {
        uplevel #0 [concat $state(-queryprogress) \
            [list $token $state(querylength) $state(queryoffset)]]
    }
}

# Reads the reply: the status line, the headers, and the body.
proc http::Event {token} {
    variable $token
    upvar 0 $token state
    set sock $state(sock)
    if {$state(state) eq "header"} {
        while {1} {
            if {[catch {gets $sock line} n]} {
                Finish $token $n
                return
            }
            if {$n < 0} {
                if {[eof $sock]} {
                    if {$state(http) eq "" && $state(reusing) && [Retry $token]} return
                    Eof $token
                }
                return
            }
            set line [string trimright $line \r]
            if {$state(http) eq ""} {
                if {$line eq ""} continue
                set state(http) $line
                continue
            }
            if {$line ne ""} {
                if {[regexp {^([^:]+):[ \t]*(.*)$} $line -> k v]} {
                    set v [string trim $v]
                    lappend state(meta) $k $v
                    switch -- [string tolower $k] {
                        content-type {
                            set state(type) $v
                            if {[regexp -nocase {charset\s*=\s*"?([^";]+)} $v -> cs]} {
                                set state(charset) [string trim $cs]
                            }
                        }
                        content-length {set state(totalsize) [string trim $v]}
                        content-encoding {set state(coding) [string tolower $v]}
                        transfer-encoding {set state(transfer) [string tolower $v]}
                        connection {set state(connection) [string tolower $v]}
                    }
                }
                continue
            }
            # The end of the headers.
            set code [ncode $token]
            if {$code ne "" && $code >= 100 && $code < 200 && $code != 101} {
                # An interim reply: the real one follows.
                set state(http) ""
                set state(meta) {}
                continue
            }
            Body $token
            return
        }
    }
    if {[info exists state(-handler)]} {
        fileevent $sock readable {}
        if {[catch {uplevel #0 [concat $state(-handler) [list $sock $token]]} n]} {
            Finish $token $n
            return
        }
        if {![info exists state(sock)]} return
        if {[string is integer -strict $n]} {incr state(currentsize) $n}
        Progress $token
        if {[eof $sock] || ($state(totalsize) > 0 && $state(currentsize) >= $state(totalsize))} {
            Done $token
        } elseif {$state(status) eq ""} {
            fileevent $sock readable [list http::Event $token]
        }
        return
    }
    if {[catch {
        if {$state(state) eq "chunked"} {
            Chunks $token
        } else {
            set n $state(-blocksize)
            if {$state(state) eq "length"} {
                set n [expr {min($n, $state(totalsize) - $state(currentsize))}]
            }
            set block [read $sock $n]
            if {$block ne ""} {
                incr state(currentsize) [string length $block]
                Store $token $block
                Progress $token
            }
            if {$state(state) eq "length" && $state(currentsize) >= $state(totalsize)} {
                Done $token
            } elseif {[eof $sock]} {
                set state(connection) close
                Done $token
            }
        }
    } err]} {
        Finish $token $err
    }
}

# Sets up the read of the body, after the headers.
proc http::Body {token} {
    variable $token
    upvar 0 $token state
    set state(binary) $state(-binary)
    if {!$state(binary)} {
        set t [string tolower [lindex [split $state(type) {;}] 0]]
        set t [string trim $t]
        if {![string match text/* $t] && ![regexp {^application/(xml|.*\+xml|json|.*\+json|javascript|x-www-form-urlencoded|x-tcl)$} $t]} {
            set state(binary) 1
        }
    }
    set code [ncode $token]
    if {$state(method) eq "HEAD" || $code in {204 304}} {
        Done $token
        return
    }
    if {[string match *chunked* $state(transfer)]} {
        set state(state) chunked
        set state(chunk) -1
    } elseif {[string is integer -strict $state(totalsize)] && $state(totalsize) >= 0 &&
            [lsearch -nocase [dict keys $state(meta)] content-length] >= 0} {
        set state(state) length
        if {$state(totalsize) == 0} {
            Done $token
            return
        }
    } else {
        set state(state) eof
        # A reply with no length ends at the end of the data.
        set state(connection) close
    }
    # The rest of the reply may be in the buffer of the channel.
    Event $token
}

# Reads chunks: a size line, the data, and the end of the line, until
# the chunk of size 0 and its trailer.
proc http::Chunks {token} {
    variable $token
    upvar 0 $token state
    set sock $state(sock)
    while {1} {
        if {$state(chunk) < 0} {
            if {[gets $sock line] < 0} break
            set line [string trim $line]
            if {$line eq ""} continue
            if {![scan $line %x size]} {
                Finish $token "bad chunk size \"$line\""
                return
            }
            if {$size == 0} {
                set state(chunk) -2
                continue
            }
            set state(chunk) $size
        } elseif {$state(chunk) == -2} {
            # The trailer ends at an empty line.
            if {[gets $sock line] < 0} break
            if {[string trim $line] eq ""} {
                Done $token
                return
            }
        } else {
            set n [expr {min($state(chunk), $state(-blocksize))}]
            set block [read $sock $n]
            if {$block eq ""} break
            incr state(chunk) -[string length $block]
            incr state(currentsize) [string length $block]
            set state(totalsize) $state(currentsize)
            Store $token $block
            Progress $token
            if {$state(chunk) == 0} {set state(chunk) -1}
        }
    }
    if {[eof $sock]} {
        set state(connection) close
        Done $token
    }
}

# Keeps a block of the body: in state(body), or in the -channel when
# the body needs no decoding.
proc http::Store {token block} {
    variable $token
    upvar 0 $token state
    if {[info exists state(-channel)] && $state(coding) in {"" identity} && $state(binary)} {
        puts -nonewline $state(-channel) $block
    } else {
        append state(body) $block
    }
}

proc http::Progress {token} {
    variable $token
    upvar 0 $token state
    if {[info exists state(-progress)] && $state(-progress) ne ""} {
        uplevel #0 [concat $state(-progress) \
            [list $token $state(totalsize) $state(currentsize)]]
    }
}

# The end of the data before the reply.
proc http::Eof {token} {
    variable $token
    upvar 0 $token state
    if {$state(http) eq ""} {
        set state(status) eof
        Finish $token
    } else {
        Done $token
    }
}

# Sends the request again on a new socket, when the server closed a
# persistent socket before it gave a reply. A POST goes again only
# with -repost.
proc http::Retry {token} {
    variable http
    variable $token
    upvar 0 $token state
    variable socketMap
    if {$state(method) eq "POST" && !$http(-repost)} {return 0}
    if {[info exists state(retried)]} {return 0}
    set state(retried) 1
    set key $state(key)
    catch {close $state(sock)}
    if {[info exists socketMap($key)] && $socketMap($key) eq $state(sock)} {
        unset socketMap($key)
    }
    set state(queryoffset) 0
    if {[info exists state(-querychannel)]} {
        catch {seek $state(-querychannel) [expr {-$state(querylength)}] current}
    }
    if {[catch {OpenSocket $token} err]} {
        Finish $token $err
    }
    return 1
}

# The reply is complete: decodes the body and finishes.
proc http::Done {token} {
    variable $token
    upvar 0 $token state
    if {[catch {
        set body $state(body)
        switch -- $state(coding) {
            gzip - x-gzip {set body [zlib gunzip $body]}
            deflate {
                if {[catch {zlib decompress $body} d]} {set d [zlib inflate $body]}
                set body $d
            }
            compress - x-compress {set body [zlib decompress $body]}
        }
        if {!$state(binary)} {
            set enc [CharsetToEncoding $state(charset)]
            if {$enc ne "binary"} {catch {set body [encoding convertfrom $enc $body]}}
        }
        if {[info exists state(-channel)] && !($state(coding) in {"" identity} && $state(binary))} {
            puts -nonewline $state(-channel) $body
            set body ""
        }
        set state(body) $body
    } err]} {
        Finish $token $err
        return
    }
    set state(status) ok
    Finish $token
}

# Ends the request: keeps or closes the socket, sets the status, and
# calls -command. With an error, the status is error.
proc http::Finish {token {errormsg ""}} {
    variable $token
    upvar 0 $token state
    global errorInfo errorCode
    if {![array exists state]} return
    if {$errormsg ne ""} {
        set state(error) [list $errormsg $errorInfo $errorCode]
        set state(status) error
    }
    catch {after cancel $state(after)}
    if {$state(sock) ne ""} {
        set sock $state(sock)
        catch {fileevent $sock readable {}}
        catch {fileevent $sock writable {}}
        if {$state(status) eq "ok" && $state(-keepalive) && [KeepOpen $token]} {
            KeepSocket $token
        } else {
            CloseSocket $token
        }
        set state(sock) ""
    } else {
        # A request in a queue leaves it.
        variable socketQueue
        if {[info exists socketQueue($state(key))]} {
            set i [lsearch -exact $socketQueue($state(key)) $token]
            if {$i >= 0} {set socketQueue($state(key)) [lreplace $socketQueue($state(key)) $i $i]}
        }
    }
    if {$state(status) eq ""} {set state(status) ok}
    if {[info exists state(-command)] && ![info exists state(done)]} {
        set state(done) 1
        if {[catch {uplevel #0 [concat $state(-command) [list $token]]} err]} {
            if {$errormsg eq ""} {
                set state(error) [list $err $errorInfo $errorCode]
                set state(status) error
            }
        }
    }
}

# 1 when the socket of a complete reply can serve the next request.
proc http::KeepOpen {token} {
    variable $token
    upvar 0 $token state
    if {![string match HTTP/1.1* $state(http)]} {return 0}
    if {"close" in [split [string map {" " ""} $state(connection)] ,]} {return 0}
    if {$state(state) eq "eof"} {return 0}
    if {$state(connection) eq "close"} {set state(connection) keep-alive}
    return 1
}

# Keeps the persistent socket for the next request of the queue. With
# TEST_EOF 0, a readable event on an idle socket closes it, as the
# server closed it.
proc http::KeepSocket {token} {
    variable $token
    upvar 0 $token state
    variable socketMap
    variable socketBusy
    variable socketQueue
    set TEST_EOF 0
    set key $state(key)
    set sock $state(sock)
    set socketBusy($key) ""
    if {[info exists socketQueue($key)] && [llength $socketQueue($key)]} {
        set next [lindex $socketQueue($key) 0]
        set socketQueue($key) [lrange $socketQueue($key) 1 end]
        variable $next
        upvar 0 $next nstate
        set nstate(sock) $sock
        set nstate(reusing) 1
        set socketBusy($key) $next
        after idle [list http::Connected $next]
        return
    }
    if {!$TEST_EOF} {
        fileevent $sock readable [list http::IdleEvent $key $sock]
    }
}

# The server closed an idle persistent socket, or sent data with no
# request.
proc http::IdleEvent {key sock} {
    variable socketMap
    variable socketBusy
    fileevent $sock readable {}
    catch {close $sock}
    if {[info exists socketMap($key)] && $socketMap($key) eq $sock} {
        unset socketMap($key)
        unset -nocomplain socketBusy($key)
    }
}

# Closes the socket of a request. The next request in the queue of a
# persistent socket opens a new one.
proc http::CloseSocket {token} {
    variable $token
    upvar 0 $token state
    variable socketMap
    variable socketBusy
    variable socketQueue
    set sock $state(sock)
    catch {close $sock}
    set key $state(key)
    if {[info exists socketMap($key)] && $socketMap($key) eq $sock} {
        unset socketMap($key)
        set socketBusy($key) ""
        if {[info exists socketQueue($key)] && [llength $socketQueue($key)]} {
            set next [lindex $socketQueue($key) 0]
            set socketQueue($key) [lrange $socketQueue($key) 1 end]
            after idle [list http::OpenQueued $next]
        }
    }
}

proc http::OpenQueued {token} {
    variable $token
    upvar 0 $token state
    if {![array exists state] || $state(status) ne ""} return
    if {[catch {OpenSocket $token} err]} {
        Finish $token $err
    }
}

proc http::reset {token {why reset}} {
    variable $token
    upvar 0 $token state
    if {![array exists state]} return
    if {$state(status) ne ""} return
    set state(status) $why
    Finish $token
}

proc http::wait {token} {
    variable $token
    upvar 0 $token state
    if {![info exists state(status)] || $state(status) eq ""} {
        vwait ${token}(status)
    }
    return [status $token]
}

proc http::data {token} {
    variable $token
    upvar 0 $token state
    return $state(body)
}

proc http::status {token} {
    variable $token
    upvar 0 $token state
    if {![info exists state(status)]} {return error}
    return $state(status)
}

proc http::code {token} {
    variable $token
    upvar 0 $token state
    return $state(http)
}

proc http::ncode {token} {
    variable $token
    upvar 0 $token state
    if {[regexp {[0-9]{3}} $state(http) code]} {return $code}
    return $state(http)
}

proc http::size {token} {
    variable $token
    upvar 0 $token state
    return $state(currentsize)
}

proc http::meta {token} {
    variable $token
    upvar 0 $token state
    return $state(meta)
}

proc http::error {token} {
    variable $token
    upvar 0 $token state
    if {[info exists state(error)]} {return $state(error)}
    return
}

proc http::cleanup {token} {
    variable $token
    upvar 0 $token state
    if {![array exists state]} return
    if {$state(status) eq ""} {reset $token}
    unset state
}

package provide http 2.9.8
