# Module ztcl::text

`ztcl::text` cuts text into the units that a reader sees: grapheme clusters, words, and sentences. It also gives the display width of text in columns. The rules are those of Unicode 18.0.0: UAX #29 for the segments, and UAX #11 with UTS #51 for the width. [References](../references/text.md) lists the sources.

Tcl counts code points. A user sees one character in `e` + U+0301 (a combining accent), in a flag (two regional indicators), and in a family emoji (several emoji joined by U+200D). `string length` gives 2, 2, and 5 for them. A grapheme cluster is the unit of the user:

```tcl
package require ztcl::text
set s "é\U1F1FA\U1F1F8\U1F468‍\U1F469‍\U1F467"
puts [string length $s]               ;# 9
puts [string length -grapheme $s]     ;# 3
puts [llength [ztcl::text graphemes $s]]   ;# 3
```

The module needs no capability. The `-grapheme` forms of `string` and `split` need the module in the build, and no `package require`. The plain forms of `string length`, `string index`, `string range`, `string reverse`, and `split` keep the behavior of Tcl.

## Synopsis

```tcl
package require ztcl::text
ztcl::text graphemes STRING
ztcl::text words ?-all? STRING
ztcl::text sentences STRING
ztcl::text width ?-ambiguous narrow|wide? STRING
ztcl::text bounds ?-unit grapheme|word|sentence? STRING

string length -grapheme STRING
string index -grapheme STRING INDEX
string range -grapheme STRING FIRST LAST
string reverse -grapheme STRING
split STRING SPLITCHARS -grapheme
```

## Commands

### graphemes

Gives the list of the extended grapheme clusters of `STRING`. `join` of the list gives `STRING` again. A loop over the clusters is `foreach g [ztcl::text graphemes $s] {...}`.

<!-- run -->
```tcl
package require ztcl::text
foreach g [ztcl::text graphemes "Café \U1F44D\U1F3FD"] {
    puts "[string length $g] code points"
}
```

```text
1 code points
1 code points
1 code points
2 code points
1 code points
2 code points
```

### words

Gives the word segments of UAX #29 that have a letter or a number. Spaces and punctuation are segments of their own, and `-all` keeps them, so `join` of the list gives `STRING` again. The rules keep `can't`, `e.g`, `3.14`, and `example.com` in one segment.

<!-- run -->
```tcl
package require ztcl::text
puts [ztcl::text words "Don't stop: 3.14 is pi."]
puts [ztcl::text words -all "a, b"]
```

```text
Don't stop 3.14 is pi
a , { } b
```

### sentences

Gives the sentences of UAX #29. Each sentence has its closing marks, its spaces, and its line end.

<!-- run -->
```tcl
package require ztcl::text
puts [ztcl::text sentences "It is 3.5 m long. Is it? Yes."]
```

```text
{It is 3.5 m long. } {Is it? } Yes.
```

### width

Gives the count of columns of `STRING` in a terminal or a monospace font. Each grapheme cluster has the largest width of its code points, plus the width of each spacing mark and each conjunct consonant in it (such as `\u093F` in `\u0915\u093F`):

| Code points | Columns |
|---|---|
| Marks, format characters except U+00AD, controls, default ignorables, and the medial and final jamo of Hangul | 0 |
| East Asian Wide and Fullwidth, and emoji with emoji presentation | 2 |
| East Asian Ambiguous, such as `±` and the Greek letters | 1, or 2 with `-ambiguous wide` |
| Each other code point | 1 |

U+FE0F after an emoji makes the cluster 2 columns. A flag (two regional indicators) is 2 columns. The widths equal the cursor moves of libghostty-vt, the terminal of `ztcl::vt`, with grapheme clusters on (mode 2027), and a test checks them.

<!-- run -->
```tcl
package require ztcl::text
puts [ztcl::text width "ab中"]
puts [ztcl::text width "❤️ é"]
puts [ztcl::text width -ambiguous wide "±"]
```

```text
4
4
2
```

### bounds

Gives the character index of each boundary of a unit (`grapheme` by default), from 0 to the length of `STRING`. The indexes are those of `string index` and `string range`.

<!-- run -->
```tcl
package require ztcl::text
puts [ztcl::text bounds "aéb"]
puts [ztcl::text bounds -unit word "hi there"]
```

```text
0 1 3 4
0 2 3 8
```

### The -grapheme forms

`string length -grapheme`, `string index -grapheme`, `string range -grapheme`, and `string reverse -grapheme` count in grapheme clusters. The indexes take `end`, `end-N`, and `M+N` as in Tcl. `string reverse -grapheme` keeps the code points of each cluster in order, so an accent stays on its letter.

`split STRING SPLITCHARS -grapheme` cuts at the clusters. An empty `SPLITCHARS` gives each cluster. Else the string is cut at each cluster that is one of the characters of `SPLITCHARS`, so a comma with an accent on it is not a separator. Each form has one more argument than the plain form, so in Tcl each form is an error.

<!-- run -->
```tcl
set s "não"
puts [string length -grapheme $s]
puts [string equal [string index -grapheme $s 1] "ã"]
puts [string equal [string reverse -grapheme $s] "oãn"]
puts [llength [split $s "" -grapheme]]
```

```text
3
1
1
3
```

## Speed

The tables are 23,584 bytes, in three stages, and one lookup gives each property of a code point. A text of ASCII and Latin letters (U+0000 to U+02FF) goes 16 or 32 bytes at a time with vector instructions. A string of 256 bytes or more keeps a list of the byte offset of every 64th cluster until the next garbage collection, so a loop of `string index -grapheme` on one string does not walk from the start each time. [Performance](../performance.md#text) has the numbers.

Each command uses one compute unit for each 4,096 bytes of its string.

## Errors

| Command | Message |
|---|---|
| `ztcl::text width -x a` | `wrong # args: should be "ztcl::text width ?-ambiguous narrow\|wide? string"` |
| `ztcl::text width -ambiguous big a` | `bad value "big": must be narrow or wide` |
| `ztcl::text bounds -unit line a` | `bad unit "line": must be grapheme, word, or sentence` |
| `string length -grapheme x` in a build with no module | `-grapheme needs the module ztcl::text in the build` |

## Platforms

Each target, and WebAssembly. `-Dbatteries=core` leaves the module and its tables out of the build.

## In Zig

`@import("ztcl").text` is the segmenter for a Zig program: `graphemeEnd`, `graphemeBefore`, `skip`, `count`, `Words`, `wordAt`, `Sentences`, `clusterWidth`, and `width`. `ztk` uses it for the cursor, the selection, and the line wrap of its text widgets.
