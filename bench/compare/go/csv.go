// Reads a CSV file of sales and writes the quantity and the revenue for
// each region and product.
package main

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
)

func main() {
	f, err := os.Open(filepath.Join(os.Args[1], "sales.csv"))
	if err != nil {
		panic(err)
	}
	defer f.Close()
	r := csv.NewReader(bufio.NewReader(f))
	r.ReuseRecord = true
	if _, err := r.Read(); err != nil {
		panic(err)
	}
	qty := map[string]int64{}
	rev := map[string]float64{}
	var totalQty int64
	var totalRev float64
	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			panic(err)
		}
		q, _ := strconv.ParseInt(rec[3], 10, 64)
		p, _ := strconv.ParseFloat(rec[4], 64)
		v := float64(q) * p
		key := rec[1] + "|" + rec[2]
		qty[key] += q
		rev[key] += v
		totalQty += q
		totalRev += v
	}
	keys := make([]string, 0, len(qty))
	for k := range qty {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Printf("%s|%d|%.2f\n", k, qty[k], rev[k])
	}
	fmt.Printf("TOTAL|%d|%.2f\n", totalQty, totalRev)
}
