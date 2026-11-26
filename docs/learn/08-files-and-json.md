# Files and JSON

`open` gives a channel, and `gets`, `read`, `puts`, and `close` work on it. `ztcl::json` reads and writes JSON. This lesson keeps the notes of `jot` in `notes.json`.

The shell of this page has the file `notes.json`, and it is read-only. The example that writes a file runs in `ztcl` on your computer.

<!-- checkpoint: --root . --allow file,channels -->
```tcl
package require ztcl::json
```

<!-- file: notes.json -->
```json
[{"text": "buy milk", "done": true}, {"text": "fix the bike #home", "done": false}]
```

## Read a file

[`set f [open notes.json]`](run:) opens the file and gives a channel name. [`set text [read $f]`](run:) reads all of it, and [`close $f`](run: "") closes the channel. `gets $f line` reads one line and gives its length, or -1 at the end of the file.

## Parse JSON

[`set notes [ztcl::json parse $text]`](run: "{text {buy milk} done true} {text {fix the bike #home} done false}") makes Tcl values: an object is a dict, and an array is a list. Now the dict commands work: [`dict get [lindex $notes 1] text`](run: "fix the bike #home"). `ztcl::json get` reads one value with no full parse: [`ztcl::json get $text 0 done`](run: "true").

Bad JSON is an error with its line and column: [`ztcl::json parse {[1,}`](run: "error: json syntax error at line 1, column 4: value expected").

## Write JSON

A Tcl value has no visible type: `0` is a number, a string, and a boolean. `encode` needs a schema for the types. [`ztcl::json encode -schema {list {object {text string done bool}}} $notes`](run: "[{\"text\":\"buy milk\",\"done\":true},{\"text\":\"fix the bike #home\",\"done\":false}]") gives the JSON of the notes. A guess with `-auto` makes a number of the canonical text of a number. `0` becomes a number, and `007` stays a string: [`ztcl::json encode -auto {text 007 done 0}`](run: "{\"text\":\"007\",\"done\":0}").

This script saves the notes and reads them again. Run it in `ztcl` on your computer.

<!-- run: --root . --allow file,channels -->
```tcl
package require ztcl::json
set notes [list [dict create text "buy milk" done 1]]
set f [open notes.json w]
puts $f [ztcl::json encode -schema {list {object {text string done bool}}} $notes]
close $f
set f [open notes.json]
puts [ztcl::json parse [read $f]]
close $f
```

```text
{text {buy milk} done true}
```

## Files are a capability

In ztcl, files and channels are a capability. The `ztcl` program has them, and `ztcl --root DIR` keeps each path inside one folder. An app that embeds ztcl turns them on or keeps them off. [Limits and capabilities](../limits.md) tells how.

## Reading code an agent wrote

- Each `open` has a `close`, also on the path of an error. Look for `try` with `finally { close $f }`.
- A file name from input goes through a check, or the program runs with `--root`. A name such as `../../.ssh/config` leaves the folder.
- JSON goes out through `encode` with a schema. With `-auto`, a note with the text `0` or `true` becomes a number or a boolean.
- A missing key of the JSON gives an error at `dict get`. The code checks with `dict exists`.

## Ask an agent

> Write procs `jot::load` and `jot::save` that keep the notes in notes.json. Use `ztcl::json encode -schema` for the types, and `try` with `finally` to close each channel.

## Try this

- Read the file one line at a time with `gets` in a `while` loop.
- Run `ztcl::json encode -schema {list {object {text string done bool}}} {{text x}}`, and read the error.
- Run `ztcl::json get $text 1 text`.
