# Module ztcl::json

ztcl has built-in modules under the namespace `ztcl`. A module loads with `package require` and needs no capability unless its page says so. `ztcl::json` is the first module. More modules come with the [Batteries milestone](https://github.com/beetlebugorg/ztcl/milestone/2).

> [!NOTE]
> `ztcl::json` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

`ztcl::json` reads and writes JSON (RFC 8259). The parser is a Zig implementation of the simdjson algorithm: a first pass finds the structural bytes 64 bytes at a time with vectors, and a second pass makes Tcl values from their positions. [References](../references/stdlib.md#json) lists the sources.

```tcl
package require ztcl::json
set text {{"name": "ztcl", "tags": ["tcl", "zig"]}}
set d [ztcl::json parse $text]
puts [dict get $d name]            ;# ztcl
puts [ztcl::json get $text tags 1]   ;# zig, with no full parse
```

`ztcl::json parse` is faster than `JSON.parse` of Node.js and each Python parser on two of the three standard test files, and `ztcl::json get` is faster on all three. [Performance](../performance.md#json) has the numbers.

The module needs no capability. `package require json` and `package require json::write` give the tcllib names over the same code.

## Try it

The shell below has `ztcl::json` and two sample files, `users.json` and `config.json`. The proc `readfile` gives the text of a file. Type `set d [ztcl::json parse -null null [readfile users.json]]` and then `puts $d`, or use the inspector under the shell.

<!-- shell -->
```tcl
package require ztcl::json
proc readfile {name} {
    set f [open $name]
    try { read $f } finally { close $f }
}
```

<!-- file: users.json -->
```json
{
  "page": 1,
  "users": [
    {"id": 7, "name": "Ada", "langs": ["tcl", "zig"], "admin": true},
    {"id": 9, "name": "Bob", "langs": [], "admin": false, "team": null}
  ]
}
```

<!-- file: config.json -->
```json
{"window": {"width": 640, "height": 480, "title": "Notes"},
 "recent": ["todo.txt", "plan.md"], "theme": "dark", "scale": 1.5}
```

The inspector shows a JSON value as a tree. An object is a list of keys, and an array is a list of numbered items. Select a node, and the command line of the inspector gets the Tcl path of the node in `$d`. The button puts the command into the shell. Paste your own JSON in the text box, or pick a sample file. In the shell, Alt-I shows the last result as a tree too, and the variable `_` gets the result, so the paths of that tree use `$_`.

<!-- helper: JSON inspector -->
```tcl
# height: 492
helper::form
helper::row Source [ttk::combobox .f.src -textvariable src -state readonly -values {users.json config.json "the text below"}]
text .f.text -height 3 -font TkFixedFont -wrap char -relief solid -borderwidth 1
helper::row Text .f.text
helper::row Show [ttk::combobox .f.show -textvariable show -state readonly -values {"set d" pretty "the selected node"}]
ttk::treeview .f.tree -columns value -height 7
.f.tree heading #0 -text Path
.f.tree heading value -text Value
helper::row Tree .f.tree
helper::footer 2
set src users.json
set show "set d"
set path {}

# The text of the source, as a Tcl word for the command.
proc source_word {} {
    if {$::src eq "the text below"} { return [list [.f.text get 1.0 end-1c]] }
    return "\[readfile $::src\]"
}
proc build {} {
    set parse "ztcl::json parse -null null [source_word]"
    switch -- $::show {
        "set d" { helper::show "set d \[$parse\]" }
        pretty { helper::show "ztcl::json pretty [source_word]" }
        default {
            helper::show $::path
            helper::run "[list apply [list d $::path]] \[$parse\]" helper::result
        }
    }
    helper::run "ztcl::json parse -typed -null null [source_word]" fill
}
# Fills the tree from the -typed form. A node is a value word (base:
# $d or a command in brackets) and a list of dict keys in it.
proc fill {ok typed} {
    .f.tree delete [.f.tree children {}]
    if {$ok} { add {} d {$d} {} $typed }
}
proc word {base keys} {
    if {$keys eq ""} { return $base }
    return "\[dict get $base $keys\]"
}
proc add {parent name base keys node} {
    lassign $node type v
    switch -- $type {
        object { set shown "{[expr {[llength $v] / 2}] keys}" }
        array { set shown "\[[llength $v] items\]" }
        null { set shown null }
        default { set shown $v }
    }
    set id [.f.tree insert $parent end -text $name -values [list $shown] -open [expr {$parent eq ""}]]
    set w [word $base $keys]
    set ::paths($id) [expr {$w eq {$d} ? "set d" : [string range $w 1 end-1]}]
    if {$type eq "object"} {
        foreach {k child} $v { add $id $k $base [linsert $keys end $k] $child }
    } elseif {$type eq "array"} {
        set i 0
        foreach child $v {
            add $id $i "\[lindex $w $i\]" {} $child
            incr i
        }
    }
}
bind .f.tree <<TreeviewSelect>> {
    set sel [.f.tree selection]
    if {$sel ne ""} {
        set path $paths($sel)
        if {$path ne "set d"} { set show "the selected node" } else { set show "set d" }
        build
    }
}
bind .f.text <KeyRelease> { if {$src eq "the text below"} build }
proc load {} {
    if {$::src eq "the text below"} return
    helper::run [list readfile $::src] {apply {{ok t} { .f.text delete 1.0 end; .f.text insert end $t }}}
}
trace add variable src write "load ;#"
load
helper::watch build src show
```

## Commands

### parse

```tcl
ztcl::json parse ?-null VALUE? ?-typed? ?--? TEXT
```

Gives the Tcl value of a JSON text:

| JSON | Tcl |
|---|---|
| object | a dict. A key that comes again keeps its first place and gets the last value, as `dict create` does. |
| array | a list |
| string | a string |
| number | an integer that fits in 64 bits is an int, a larger integer is its decimal text (a big integer of `expr`), and other numbers are doubles. `1.0` gives `1.0`, and `1e2` gives `100.0`. |
| `true`, `false` | the strings `true` and `false` |
| `null` | an error with the code `ZT JSON NULL`, unless `-null VALUE` gives the value |

A lone surrogate in a `\u` escape becomes U+FFFD.

`-typed` gives a tagged tree that keeps each JSON type: `{object {KEY TREE ...}}`, `{array {TREE ...}}`, `{string S}`, `{number TEXT}`, `{bool true}`, and `null`. A number keeps its text.

### valid

```tcl
ztcl::json valid TEXT
```

Gives 1 for a valid JSON text and 0 for another text.

### get and exists

```tcl
ztcl::json get ?-null VALUE? ?--? TEXT ?STEP ...?
ztcl::json exists TEXT ?STEP ...?
```

`get` gives the value at a path. A step is a key in an object or a decimal index in an array. The walk uses the structural index of the text and makes only the value at the end of the path. It checks the brackets of each value that it skips, and it does not check the scalars in them, so `get` can give a value of a text that `valid` rejects. A path with no value is an error with the code `ZT JSON PATH`. `exists` gives 1 or 0.

### encode

```tcl
ztcl::json encode -schema SCHEMA VALUE
ztcl::json encode -typed TREE
ztcl::json encode -auto VALUE
```

A Tcl value has no visible type, so `encode` needs a schema or a typed tree. The schema words:

| Word | JSON |
|---|---|
| `string` | a string |
| `int` | an integer, also above 64 bits |
| `number` | a number. Inf and NaN are errors. |
| `bool` | `true` or `false`, from each boolean of Tcl |
| `null` | `null` |
| `raw` | the value is JSON text |
| `object` | a dict, with each value guessed |
| `{object SCHEMA}` | a dict. SCHEMA is a dict of keys and schemas, and the output has its keys in that order. A missing key and a key that SCHEMA does not name are errors. |
| `{list WORD}` | a list, each element with WORD |
| `{optional WORD}` | in `{object SCHEMA}`: the key can be absent |

A guess makes a number of the canonical text of an integer or a double, a bool of `true` and `false`, and a string of each other value. `-auto VALUE` is `-schema object VALUE`.

### The builders

```tcl
ztcl::json object ?KEY JSON ...?
ztcl::json array ?JSON ...?
ztcl::json string S
ztcl::json number N
ztcl::json bool B
ztcl::json null
ztcl::json raw JSON
```

Each builder gives JSON text with no spaces. A value of `object` and an element of `array` is JSON text, for example the result of another builder. `raw` checks its text.

### pretty

```tcl
ztcl::json pretty ?-indent N? TEXT
```

Gives the text with one member on each line and N spaces (2 by default) for each level.

## Errors

| Code | Cause |
|---|---|
| `ZT JSON SYNTAX LINE COLUMN` | a syntax error, invalid UTF-8, or a control character in a string |
| `ZT JSON DEPTH` | nesting deeper than 512 |
| `ZT JSON NUMBER` | a number of more than 1 MiB of text |
| `ZT JSON NULL` | a `null` with no `-null` |
| `ZT JSON PATH` | a path of `get` with no value |
| `ZT JSON SCHEMA`, `ZT JSON TYPED`, `ZT JSON VALUE` | an error of `encode` |

## Limits

The first pass runs in chunks of 64 KiB. After each chunk, a command pays one compute unit of the compute limit for each 4,096 bytes and one compute unit for each value that it made, and it checks the memory limit. So a limit stops a parse of a large text within one chunk. A string with no escape is a slice of the text, so the text stays in memory while a part of it lives.

## The tcllib names

`package require json` gives `json::json2dict`, `json::many-json2dict`, `json::validate`, `json::list2json`, and `json::string2json`. `package require json::write` gives `json::write` with `indented`, `aligned`, `string`, `array`, `array-strings`, `object`, and `object-strings`, with the layout of tcllib. `json::json2dict` gives `null` as the string `null` and keeps the text of each number, as tcllib does.

`json::json2dict` and `json::validate` also accept the numbers `1.` and `.1`, as tcllib does. The new API follows RFC 8259 and rejects them.

`tools/tcllib-tests.sh json json_write` runs the test files of tcllib 2.0 on ztcl. `json_write.test` passes its 15 tests. `json.test` passes 506 of 512. These cases differ from tcllib:

- A bad escape in a string gives the message of ztcl, for example `json syntax error at line 1, column 3: bad escape`. tcllib gives `unexpected token ""\%"" at position 0; expecting STRING`. The tests `json-tcl-8.1` to `json-tcl-8.6` check these messages.
