// The TechEmpower plaintext and JSON tests in Go net/http:
//   go run server.go PORT [h2c]
// SPDX-License-Identifier: BSD-2-Clause
package main

import (
	"encoding/json"
	"net/http"
	"os"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "go")
		w.Write([]byte("Hello, World!"))
	})
	mux.HandleFunc("/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Server", "go")
		json.NewEncoder(w).Encode(map[string]string{"message": "Hello, World!"})
	})
	var h http.Handler = mux
	if len(os.Args) > 2 && os.Args[2] == "h2c" {
		h = h2c.NewHandler(mux, &http2.Server{})
	}
	if err := http.ListenAndServe("127.0.0.1:"+os.Args[1], h); err != nil {
		panic(err)
	}
}
