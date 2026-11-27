# A manual of several pages from Markdown: numbered sections, an
# outline, links between sections, code blocks, notes, and an index.
source [file join [file dirname [info script]] common.tcl]
set out [expr {$argc > 0 ? [lindex $argv 0] : "manual.pdf"}]

set doc [ztcl::pdf create]
set fonts [loadFonts $doc]
ztcl::pdf info $doc Title "The widget manual"
set text {
# The widget manual {#manual}

This manual shows the Markdown input of `ztcl::typeset`. Each heading of level two gets a number, the outline of the PDF reader lists each heading, and a reference such as [](#install) is a link.{^links}

## Install the widget {#install}

Copy the file to the folder of your project, and load it with `source`. The widget needs no other package.{^install}

```tcl
source widget.tcl
widget::create .w -title "Status"
```

> [!NOTE]
> The widget runs in each build of ztcl, because it uses only the commands of the core language.

## Use the widget {#use}

Each call of `widget::set` changes one field. The changes show at the next update of the window. See [](#install) for the setup, and [](#limits) for the limits of the fields.{^fields}

## Limits {#limits}

A title has at most 80 characters. A field has at most 4,096 characters, and the widget shows the first 200 of them.{^limits}
}
set stats [ztcl::typeset markdown $doc $text -fonts $fonts -style {page_w 420 page_h 595 inner 54 outer 54 top 70 lines 32}]
puts "[dict get $stats pages] pages, [dict get $stats lines] lines"
save $doc $out
