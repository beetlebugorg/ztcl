# Lists and dicts

A list is a string in a fixed format: words with spaces between them, and braces around a word that has a space. A dict is a list of keys and values. This lesson makes the notes of `jot` a list of dicts.

<!-- checkpoint -->
```tcl
set note "buy milk"
set count 1
```

## Lists

`list` makes a list and adds the braces that each word needs: [`set tags [list home "the shop" work]`](run: "home {the shop} work"). [`llength $tags`](run: "3") counts the elements, and [`lindex $tags 1`](run: "the shop") gets one. The first index is 0, and `end` is the last one: [`lindex $tags end`](run: "work").

`lappend` adds to a list in a variable: [`lappend tags garden`](run: "home {the shop} work garden"). [`lsort $tags`](run: "garden home {the shop} work") sorts it, [`lsearch $tags work`](run: "2") finds an element, and [`join $tags ", "`](run: "home, the shop, work, garden") makes one string.

| Tcl | Python |
|---|---|
| `list a b c` | `["a", "b", "c"]` |
| `lindex $l 0` | `l[0]` |
| `lrange $l 1 end` | `l[1:]` |
| `lappend l d` | `l.append("d")` |
| `foreach x $l { ... }` | `for x in l:` |

## A list made with quotes

A string in quotes is a list only when its words are right. [`set name "the shop"`](run: "the shop") has a space. [`llength "home $name"`](run: "3") gives 3: the quotes made the text `home the shop`, and `the shop` is now two elements. [`llength [list home $name]`](run: "2") keeps `the shop` as one element. Build a list with `list` and `lappend`, and never with quotes.

## Dicts

[`set n [dict create text "buy milk" done 0]`](run: "text {buy milk} done 0") makes a dict for a note. [`dict get $n text`](run: "buy milk") gets a value, and [`dict set n done 1`](run: "text {buy milk} done 1") changes the variable. A missing key is an error: [`dict get $n tags`](run: "error: key \"tags\" not known in dictionary"). Check with [`dict exists $n tags`](run: "0") first.

Now the notes of `jot` are a list of dicts. [`set notes [list $n [dict create text "fix the bike" done 0]]`](run: "{text {buy milk} done 1} {text {fix the bike} done 0}") makes it, and [`dict get [lindex $notes 1] text`](run: "fix the bike") reads the second note. [`lmap x $notes {dict get $x text}`](run: "{buy milk} {fix the bike}") gets the text of each note.

## Reading code an agent wrote

- A list is built with `list`, `lappend`, or `lmap`. Look for a list built with `"..."` and a value that can have a space.
- `lindex` and `dict get` get one value. A string such as `"a {b"` is not a list, and a list command on it is an error.
- A `dict get` of a key that can be missing has a `dict exists` before it.
- An index starts at 0, and `end-1` is the second to last.

## Ask an agent

> Store each note as a Tcl dict with the keys text, done, and tags. Use `dict exists` before each `dict get` of an optional key.

## Try this

- Add a third note to `notes` with `lappend` and `dict create`.
- Get the text of the last note with `lindex` and `end`.
- Run `dict keys $n` and `dict values $n`.
