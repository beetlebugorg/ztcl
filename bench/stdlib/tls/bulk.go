// The bulk speed of Go AEAD on 16 KiB records: go run bulk.go
// Prints "aes-128-gcm MB/s" and "chacha20-poly1305 MB/s".
// SPDX-License-Identifier: BSD-2-Clause
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"fmt"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
)

func run(name string, a cipher.AEAD) {
	buf := make([]byte, 16384, 16384+16)
	nonce := make([]byte, a.NonceSize())
	best := 0.0
	for r := 0; r < 5; r++ {
		t := time.Now()
		n := 0
		for time.Since(t) < 300*time.Millisecond {
			a.Seal(buf[:0], nonce, buf[:16384], nil)
			n++
		}
		mb := float64(n) * 16384 / 1e6 / time.Since(t).Seconds()
		if mb > best {
			best = mb
		}
	}
	fmt.Printf("%s %.1f\n", name, best)
}

func main() {
	key := make([]byte, 16)
	b, _ := aes.NewCipher(key)
	g, _ := cipher.NewGCM(b)
	run("aes-128-gcm", g)
	c, _ := chacha20poly1305.New(make([]byte, 32))
	run("chacha20-poly1305", c)
}
