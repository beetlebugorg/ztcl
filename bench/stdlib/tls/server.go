// A TLS 1.3 server in Go crypto/tls for openssl s_time:
//   go run server.go PORT CERT KEY
// It answers each connection with a short HTTP response and closes it.
// SPDX-License-Identifier: BSD-2-Clause
package main

import (
	"bufio"
	"crypto/tls"
	"net"
	"os"
)

func main() {
	cert, err := tls.LoadX509KeyPair(os.Args[2], os.Args[3])
	if err != nil {
		panic(err)
	}
	cfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13,
		CurvePreferences: []tls.CurveID{tls.X25519}}
	ln, err := tls.Listen("tcp", "127.0.0.1:"+os.Args[1], cfg)
	if err != nil {
		panic(err)
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			r := bufio.NewReader(c)
			for {
				line, err := r.ReadString('\n')
				if err != nil {
					return
				}
				if line == "\r\n" || line == "\n" {
					c.Write([]byte("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"))
					return
				}
			}
		}(c)
	}
}
