// Opens COUNT TLS 1.3 connections. Each one does a full handshake, reads
// 1 MiB to the end, and closes.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"os"
	"strconv"
)

func main() {
	port, cafile := os.Args[1], os.Args[2]
	count, _ := strconv.Atoi(os.Args[3])
	pem, err := os.ReadFile(cafile)
	if err != nil {
		panic(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)
	cfg := &tls.Config{RootCAs: pool, ServerName: "localhost", MinVersion: tls.VersionTLS13}
	total := 0
	for i := 0; i < count; i++ {
		c, err := tls.Dial("tcp", "127.0.0.1:"+port, cfg)
		if err != nil {
			panic(err)
		}
		n, err := io.Copy(io.Discard, c)
		if err != nil {
			panic(err)
		}
		total += int(n)
		c.Close()
	}
	fmt.Println(total)
}
