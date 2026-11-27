// An HTTP/1.1 server with keep-alive from net/http. The runner sets
// GOMAXPROCS=1, so the server uses one thread for Go code.
package main

import (
	"fmt"
	"net/http"
	"os"
)

var body = []byte(`{"ok":true,"n":42}`)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	})
	srv := &http.Server{Addr: "127.0.0.1:" + os.Args[1]}
	fmt.Println("ready")
	if err := srv.ListenAndServe(); err != nil {
		panic(err)
	}
}
