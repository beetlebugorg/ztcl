// Reads 1M strings and sorts them.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

func main() {
	text, err := os.ReadFile(filepath.Join(os.Args[1], "strs.txt"))
	if err != nil {
		panic(err)
	}
	xs := strings.Fields(string(text))
	slices.Sort(xs)
	n := len(xs)
	fmt.Println(n, xs[0], xs[n/2], xs[n-1])
}
