# Module ztcl::tls

`ztcl::tls socket` opens a TLS 1.3 connection to a server and gives a channel. The script reads and writes the channel with `gets`, `read`, `puts`, and `close`, as a channel of `socket`. The TLS code is part of ztcl: the record layer, the handshake, the X.509 chain checks, and the trust stores are Zig code in the program. [References](../references/stdlib.md#tls) lists the RFCs and the test sets.

> [!NOTE]
> `ztcl::tls` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now. This version has the client only.

```tcl
package require ztcl::tls
set s [ztcl::tls socket example.com 443]
puts -nonewline $s "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
flush $s
puts [gets $s]   ;# HTTP/1.1 200 OK
close $s
```

The module needs the capabilities `socket` and `channels`. The `ztcl` program turns them on with `--allow socket,channels`. The network policy of the embedder applies as it does to `socket`: the default policy allows loopback addresses only, so the example above also needs `--net any` or a rule for the host.

## Synopsis

```tcl
ztcl::tls socket ?-servername NAME? ?-alpn PROTOCOLS? ?-cadata PEM? ?-verify BOOLEAN? HOST PORT
```

The command connects to `HOST` on `PORT` with TCP and runs the handshake before it returns. It gives the name of the channel, such as `sock3`. A failed handshake closes the connection and gives an error.

| Option | Default | What it does |
|---|---|---|
| `-servername NAME` | `HOST` | The DNS name for SNI and for the check of the certificate. Use it when `HOST` is an address. |
| `-alpn PROTOCOLS` | none | A list of up to 8 ALPN protocols, such as `{h2 http/1.1}`. |
| `-cadata PEM` | the store of the system | The trust anchors as PEM text. The store of the system is not used then. |
| `-verify BOOLEAN` | `1` | With `0`, the chain and the host name are not checked. The signature of the handshake is always checked. Use `0` for tests only. |

## The checks

The client offers X25519, P-256, and P-384 for the key exchange, and the suites AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305. It checks the chain of the server with the rules of RFC 5280, the host name with the rules of RFC 6125, and the dates against the clock of the host.

The trust anchors come from the store of the system, which loads once for each process:

- Linux: the CA bundle file of the distribution.
- macOS: the keychain.
- Windows: the ROOT store.

A server that closes the TCP connection with no `close_notify` alert gives the end of the data, and `eof` gives 1. Many HTTP servers close in this way.

## Errors

| Error code | Cause |
|---|---|
| `ZTCL TLS CERTIFICATE REASON` | The chain or the host name did not pass the checks. `REASON` is, for example, `UnknownIssuer`, `HostName`, or `Expired`. |
| `ZTCL TLS ALERT NAME` | The server sent a fatal alert, such as `handshake_failure`. |
| `ZTCL TLS ERROR ALERT` | The client found an error in the data of the server and sent the alert `ALERT`, such as `unexpected_message` for data that is no TLS. `ALERT` is `none` for an error with no alert. |
| `ZTCL TLS EOF` | The server closed the connection in the handshake. |
| `ZTCL NET DENIED` | The network policy does not allow the host. |

```tcl
catch {ztcl::tls socket -servername wrong.example 127.0.0.1 8443} msg opts
puts $msg                          ;# TLS handshake failed: the certificate is not for the host name (HostName)
puts [dict get $opts -errorcode]   ;# ZTCL TLS CERTIFICATE HostName
```

## Limits of this version

- A TLS channel blocks. `fconfigure $s -blocking 0` gives an error.
- A TLS channel cannot move to another thread with `thread::transfer`.
- The client sends no certificate. A server that asks for one gets an empty Certificate message.
- There is no session resumption and no 0-RTT data.
- WebAssembly builds do not have the module.
