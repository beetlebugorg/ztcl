# Renders an HTML table of N rows from a string.Template.
import html, sys
from string import Template
row = Template("<tr><td>$id</td><td>$name</td><td>$price</td></tr>\n")
n = int(sys.argv[1])
parts = ["<table>\n"]
for i in range(n):
    parts.append(row.substitute(id=i, name=html.escape(f"Part {i % 97} & <Co>"), price=f"{(i % 1000) * 0.25:.2f}"))
parts.append("</table>")
print("".join(parts))
