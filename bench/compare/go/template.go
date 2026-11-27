// Renders an HTML table of N rows with html/template.
package main

import (
	"bufio"
	"fmt"
	"html/template"
	"os"
	"strconv"
)

type Row struct {
	ID    int
	Name  string
	Price string
}

var page = template.Must(template.New("t").Parse(
	"<table>\n{{range .}}<tr><td>{{.ID}}</td><td>{{.Name}}</td><td>{{.Price}}</td></tr>\n{{end}}</table>\n"))

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	rows := make([]Row, n)
	for i := range rows {
		rows[i] = Row{i, fmt.Sprintf("Part %d & <Co>", i%97), fmt.Sprintf("%.2f", float64(i%1000)*0.25)}
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	if err := page.Execute(w, rows); err != nil {
		panic(err)
	}
}
