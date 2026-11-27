// Counts the words of a text and writes the 20 most frequent.
package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func main() {
	text, err := os.ReadFile(filepath.Join(os.Args[1], "words.txt"))
	if err != nil {
		panic(err)
	}
	text = bytes.ToLower(text)
	counts := map[string]int{}
	tokens := 0
	words := bytes.FieldsFunc(text, func(r rune) bool { return r < 'a' || r > 'z' })
	for _, w := range words {
		counts[string(w)]++
		tokens++
	}
	fmt.Println("tokens", tokens, "distinct", len(counts))
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if counts[keys[i]] != counts[keys[j]] {
			return counts[keys[i]] > counts[keys[j]]
		}
		return keys[i] < keys[j]
	})
	for _, k := range keys[:min(20, len(keys))] {
		fmt.Println(counts[k], k)
	}
}
