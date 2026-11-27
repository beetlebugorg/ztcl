// Encodes 16 MB of bytes to base64 and decodes them again.
package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	data, err := os.ReadFile(filepath.Join(os.Args[1], "bytes.bin"))
	if err != nil {
		panic(err)
	}
	enc := base64.StdEncoding.EncodeToString(data)
	dec, err := base64.StdEncoding.DecodeString(enc)
	if err != nil {
		panic(err)
	}
	ok := "bad"
	if bytes.Equal(dec, data) {
		ok = "ok"
	}
	fmt.Println(len(enc), enc[:16], enc[len(enc)-16:], ok)
}
