// Builds one string of N formatted lines. Each line has 32 bytes.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	var b strings.Builder
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "%07d|%-12s|%10.3f\n", i, "item"+strconv.Itoa(i%1000), float64(i)*1.5/7)
	}
	out := b.String()
	fmt.Println(len(out), out[len(out)-32:len(out)-1])
}
