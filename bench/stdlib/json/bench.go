// The JSON benchmark of Go: go run bench.go MODE FILE.json
// Prints the best time of one run of MODE, in seconds, or "skip".
// SPDX-License-Identifier: BSD-2-Clause
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func get(v any, p []any) any {
	for _, k := range p {
		switch x := k.(type) {
		case string:
			v = v.(map[string]any)[x]
		case float64:
			v = v.([]any)[int(x)]
		}
	}
	return v
}

func walk(v any) int {
	n := 1
	switch x := v.(type) {
	case []any:
		for _, e := range x {
			n += walk(e)
		}
	case map[string]any:
		for _, e := range x {
			n += walk(e)
		}
	}
	return n
}

func main() {
	mode, file := os.Args[1], os.Args[2]
	data, err := os.ReadFile(file)
	if err != nil {
		panic(err)
	}
	self, _ := os.Executable()
	pdata, err := os.ReadFile(filepath.Join(os.Getenv("BENCH_JSON_DIR"), "paths.json"))
	if err != nil {
		_ = self
		panic(err)
	}
	var all map[string]struct {
		Query []any   `json:"query"`
		Read  [][]any `json:"read"`
	}
	if err := json.Unmarshal(pdata, &all); err != nil {
		panic(err)
	}
	paths := all[strings.TrimSuffix(filepath.Base(file), ".json")]
	parse := func() any {
		var v any
		if err := json.Unmarshal(data, &v); err != nil {
			panic(err)
		}
		return v
	}
	parsed := parse()
	sink := 0
	ops := map[string]func(){
		"parse": func() { _ = parse(); sink++ },
		"query": func() { sink += len(fmt.Sprint(get(parse(), paths.Query))) },
		"read3": func() {
			d := parse()
			for _, p := range paths.Read {
				sink += len(fmt.Sprint(get(d, p)))
			}
		},
		"walk": func() { sink += walk(parse()) },
		"encode": func() {
			b, err := json.Marshal(parsed)
			if err != nil {
				panic(err)
			}
			sink += len(b)
		},
	}
	op, ok := ops[mode]
	if !ok {
		fmt.Println("skip")
		return
	}
	best, total, n := 1e9, 0.0, 0
	for n < 3 || total < 0.5 {
		t := time.Now()
		op()
		s := time.Since(t).Seconds()
		if s < best {
			best = s
		}
		total += s
		n++
	}
	fmt.Printf("%.6g\n", best)
	if sink < 0 {
		fmt.Println(sink)
	}
}
