# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::tls {
    area ztcl
    since TODO
    synopsis {ztcl::tls socket ?-servername name? ?-alpn protocols? ?-cadata pem? ?-verify boolean? host port}
    summary {A TLS 1.3 client: connects to `host` on `port`, runs the handshake, checks the certificate chain and the host name, and gives a channel.}
    description {A TLS 1.3 client: connects to `host` on `port`, runs the handshake, checks the certificate chain and the host name, and gives a channel. Load it with `package require ztcl::tls`.}
    capability {socket}
    page {modules/tls.md}
    flags {--allow socket,channels}
    names ztcl::tls::socket
    option -servername {
        value name
        type TODO
        summary {The DNS name for SNI and for the check of the certificate.}
        description {The DNS name for SNI and for the check of the certificate. The default is `host`.}
    }
    option -alpn {
        value protocols
        type TODO
        summary {A list of up to 8 ALPN protocols.}
        description {A list of up to 8 ALPN protocols.}
    }
    option -cadata {
        value pem
        type TODO
        summary {The trust anchors as PEM text, in place of the store of the system.}
        description {The trust anchors as PEM text, in place of the store of the system.}
    }
    option -verify {
        value boolean
        type TODO
        summary {With 0, the chain and the host name are not checked.}
        description {With 0, the chain and the host name are not checked. The default is 1.}
    }
    subcommand socket {
        synopsis {socket ?option value ...? host port}
        summary {Opens the connection and gives the name of the channel.}
        description {Opens the connection and gives the name of the channel. A failed handshake closes the connection and gives an error.}
    }
}
