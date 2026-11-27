// Parses a web server log with a regular expression and counts the
// requests by status and by path.
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

func main() {
	f, err := os.Open(filepath.Join(os.Args[1], "access.log"))
	if err != nil {
		panic(err)
	}
	defer f.Close()
	re := regexp.MustCompile(`^\S+ \S+ \S+ \[[^\]]+\] "\S+ ([^ ?"]+)[^"]*" (\d{3}) `)
	byStatus := map[string]int{}
	byPath := map[string]int{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		m := re.FindStringSubmatch(sc.Text())
		if m != nil {
			byStatus[m[2]]++
			byPath[m[1]]++
		}
	}
	statuses := make([]string, 0, len(byStatus))
	for s := range byStatus {
		statuses = append(statuses, s)
	}
	sort.Strings(statuses)
	for _, s := range statuses {
		fmt.Println(s, byStatus[s])
	}
	paths := make([]string, 0, len(byPath))
	for p := range byPath {
		paths = append(paths, p)
	}
	sort.Slice(paths, func(i, j int) bool {
		if byPath[paths[i]] != byPath[paths[j]] {
			return byPath[paths[i]] > byPath[paths[j]]
		}
		return paths[i] < paths[j]
	})
	for _, p := range paths[:min(20, len(paths))] {
		fmt.Println(byPath[p], p)
	}
}
