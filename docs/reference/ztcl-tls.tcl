# The command reference: ztcl::tls. The format is in
# docs/dev/reference-format.md.

command ztcl::tls {
    area ztcl
    since 1.0.0-beta.1
    capability socket
    flags {--allow socket,channels,thread,event}
    setup {
        package require ztcl::tls
        # A plain TCP server on 127.0.0.1, on a port of the system, in a thread:
        # it reads 5 bytes of the ClientHello and sends the bytes of ::reply.
        set srv [thread::create {
            proc serve {c a p} {
                fconfigure $c -translation binary
                read $c 5
                puts -nonewline $c $::reply; flush $c
                after 500; close $c
            }
            set ::reply ""
            set ::port [lindex [fconfigure [socket -server serve -myaddr 127.0.0.1 0] -sockname] 2]
            thread::wait
        }]
        set port [thread::send $srv {set ::port}]
    }
    synopsis {ztcl::tls socket ?-servername NAME? ?-alpn PROTOCOLS? ?-cadata PEM? ?-verify BOOLEAN? HOST PORT}
    summary {Opens a TLS 1.3 connection to a server and gives a channel.}
    description {
        A TLS 1.3 client. `ztcl::tls socket` connects to a server, runs the handshake, checks the certificate chain and the host name, and gives a channel that the script reads and writes with `gets`, `read`, `puts`, and `close`, as a channel of `socket`. The record layer, the handshake, the X.509 checks, and the trust stores are Zig code in the program.

        Load the module with `package require ztcl::tls`. It needs the capabilities `socket` and `channels`, and the network policy of the embedder applies as it does to `socket`: the default policy allows loopback addresses only, so a server on the internet also needs `--net any` or a rule for the host. The command is also `ztcl::tls::socket`. WebAssembly builds do not have the module.

        This version has the client only. A TLS channel blocks, so `fconfigure $s -blocking 0` gives an error, and it cannot move to another thread with `thread::transfer`. The client sends no certificate, and there is no session resumption and no 0-RTT data.

        The examples of this page run with `--allow socket,channels,thread,event`. The setup starts a plain TCP server on 127.0.0.1 in a thread, so each example gets a fixed reply of a server with no handshake of its own.
    }
    returns {The name of the channel, such as `sock3`.}
    page modules/tls/
    names {ztcl::tls::socket}
    see {socket chan fconfigure}
    example {
        thread::send $srv [list set ::reply [binary decode hex 15030300020228]]
        catch {ztcl::tls socket 127.0.0.1 $port} msg opts
        list $msg [dict get $opts -errorcode]
    } {{TLS error: the server sent the alert handshake_failure (40)} {ZTCL TLS ALERT handshake_failure}}
    error {ztcl::tls bogus} {unknown or ambiguous subcommand "bogus": must be socket} {TCL LOOKUP SUBCOMMAND bogus}
    error {ztcl::tls} {wrong # args: should be "ztcl::tls subcommand ?arg ...?"} {TCL WRONGARGS}

    subcommand socket {
        synopsis {ztcl::tls socket ?-servername NAME? ?-alpn PROTOCOLS? ?-cadata PEM? ?-verify BOOLEAN? HOST PORT}
        summary {Opens the connection and gives the name of the channel.}
        description {
            Connects to HOST on PORT with TCP and runs the handshake before it returns. A failed handshake closes the connection and gives an error. The client offers X25519, P-256, and P-384 for the key exchange, and the suites AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305. It checks the chain of the server with the rules of RFC 5280, the host name with the rules of RFC 6125, and the dates against the clock of the host. The trust anchors come from the store of the system, which loads once for each process: the CA bundle file of the distribution on Linux, the keychain on macOS, and the ROOT store on Windows.

            A server that closes the TCP connection with no `close_notify` alert gives the end of the data, and `eof` gives 1. Many HTTP servers close in this way.

            The errors of the handshake: `ZTCL TLS CERTIFICATE REASON` when the chain or the host name does not pass the checks, with a REASON such as `UnknownIssuer`, `HostName`, or `Expired`; `ZTCL TLS ALERT NAME` when the server sends a fatal alert; and `ZTCL NET DENIED` when the network policy does not allow the host. Wrong data of the server gives a code with the name of the error of the Zig code and `none`, such as `ZTCL TLS EndOfStream none` ([issue 735](https://github.com/beetlebugorg/ztcl/issues/735)). The errors of the options have `-errorcode NONE`.
        }
        returns {The name of the channel.}
        see {socket close}
        argument HOST {
            type {host name or address}
            summary {The server.}
        }
        argument PORT {
            type integer
            summary {The TCP port of the server.}
        }
        example {
            thread::send $srv [list set ::reply [binary decode hex 15030300020230]]
            catch {ztcl::tls::socket 127.0.0.1 $port} msg opts
            list $msg [dict get $opts -errorcode]
        } {{TLS error: the server sent the alert unknown_ca (48)} {ZTCL TLS ALERT unknown_ca}}
        example {
            thread::send $srv [list set ::reply ""]
            catch {ztcl::tls socket 127.0.0.1 $port} msg opts
            list $msg [dict get $opts -errorcode]
        } {{TLS error: EndOfStream (alert none)} {ZTCL TLS EndOfStream none}}
        error {
            set s [socket -server {apply {{c a p} {close $c}}} -myaddr 127.0.0.1 0]
            set free [lindex [fconfigure $s -sockname] 2]
            close $s
            ztcl::tls socket 127.0.0.1 $free
        } {couldn't open socket: connection refused} {POSIX ECONNREFUSED {connection refused}}
        error {ztcl::tls socket 127.0.0.1 x} {expected integer but got "x"} NONE
        error {ztcl::tls socket 127.0.0.1 99999} {couldn't open socket: port number too high} NONE
        error {ztcl::tls socket 127.0.0.1} {wrong # args: should be "ztcl::tls socket ?-servername name? ?-alpn protocols? ?-cadata pem? ?-verify boolean? host port"} {TCL WRONGARGS}
        error {ztcl::tls socket -bogus 1 127.0.0.1 1} {bad option "-bogus": must be -alpn, -cadata, -servername, or -verify} NONE
        option -servername {
            value NAME
            type {DNS name}
            default HOST
            summary {Gives the DNS name for SNI and for the check of the certificate.}
            description {The name that the client sends in SNI and checks in the certificate. It serves a HOST that is an address.}
            example {
                thread::send $srv [list set ::reply [binary decode hex 15030300020228]]
                catch {ztcl::tls socket -servername a.example 127.0.0.1 $port} msg
                set msg
            } {TLS error: the server sent the alert handshake_failure (40)}
            error {ztcl::tls socket -servername} {wrong # args: should be "ztcl::tls socket ?-servername name? ?-alpn protocols? ?-cadata pem? ?-verify boolean? host port"} {TCL WRONGARGS}
        }
        option -alpn {
            value PROTOCOLS
            type list
            summary {Gives a list of up to 8 ALPN protocols.}
            description {The ALPN protocols that the client offers, such as `{h2 http/1.1}`.}
            example {
                thread::send $srv [list set ::reply [binary decode hex 15030300020228]]
                catch {ztcl::tls socket -alpn {h2 http/1.1} 127.0.0.1 $port} msg
                set msg
            } {TLS error: the server sent the alert handshake_failure (40)}
            error {ztcl::tls socket -alpn {a b c d e f g h i} 127.0.0.1 1} {-alpn has more than 8 protocols} NONE
        }
        option -cadata {
            value PEM
            type {PEM text}
            default {the store of the system}
            summary {Gives the trust anchors as PEM text.}
            description {The trust anchors of the check of the chain, as the PEM text of one or more certificates. The store of the system is not used then.}
            example {
                catch {ztcl::tls socket -cadata junk 127.0.0.1 $port} msg
                set msg
            } {-cadata has no certificate}
            error {ztcl::tls socket -cadata junk 127.0.0.1 1} {-cadata has no certificate} NONE
        }
        option -verify {
            value BOOLEAN
            type boolean
            default 1
            summary {Turns the checks of the chain and of the host name on or off.}
            description {With 0, the chain and the host name are not checked, for tests only. The signature of the handshake is always checked.}
            example {
                thread::send $srv [list set ::reply [binary decode hex 15030300020228]]
                catch {ztcl::tls socket -verify 0 127.0.0.1 $port} msg
                set msg
            } {TLS error: the server sent the alert handshake_failure (40)}
            error {ztcl::tls socket -verify x 127.0.0.1 1} {expected boolean value but got "x"} NONE
        }
    }
}
