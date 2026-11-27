// Parses a JSON file of records and writes it again with no spaces.
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
)

type Address struct {
	City string `json:"city"`
	Zip  string `json:"zip"`
}

type Record struct {
	ID      int64    `json:"id"`
	Name    string   `json:"name"`
	Email   string   `json:"email"`
	Active  bool     `json:"active"`
	Score   int64    `json:"score"`
	Tags    []string `json:"tags"`
	Address Address  `json:"address"`
}

func main() {
	text, err := os.ReadFile(filepath.Join(os.Args[1], "data.json"))
	if err != nil {
		panic(err)
	}
	var recs []Record
	if err := json.Unmarshal(text, &recs); err != nil {
		panic(err)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	if err := json.NewEncoder(w).Encode(recs); err != nil {
		panic(err)
	}
}
