// SPDX-License-Identifier: BSD-2-Clause
// A WASI program in Go (TinyGo) for the tests of ztcl::wasm.
package main

import (
	"fmt"
	"os"
	"strings"
)

func main() {
	words := []string{}
	for i := 0; i < 5; i++ {
		words = append(words, fmt.Sprintf("w%d", i*i))
	}
	fmt.Println("go", strings.Join(words, ","), len(os.Args))
	m := map[string]int{}
	for i := 0; i < 1000; i++ {
		m[fmt.Sprint(i%37)] += i
	}
	fmt.Println("map", len(m), m["5"])
}
