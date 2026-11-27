// Reads 1M integers and sorts them.
package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
)

func main() {
	text, err := os.ReadFile(filepath.Join(os.Args[1], "ints.txt"))
	if err != nil {
		panic(err)
	}
	var xs []int64
	for _, f := range bytes.Fields(text) {
		v, _ := strconv.ParseInt(string(f), 10, 64)
		xs = append(xs, v)
	}
	slices.Sort(xs)
	n := len(xs)
	fmt.Println(n, xs[0], xs[n/2], xs[n-1])
}
