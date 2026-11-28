# Module ztcl::typeset

`ztcl::typeset` breaks text into lines and pages. It has the total-fit line breaker of Knuth and Plass, the hyphenation of Liang with the American English patterns, font loading and metrics for TrueType fonts, and a page builder for columns with widow and orphan control. The output is data: lines, words, and their x positions. A script puts them in a PDF (`ztcl::pdf`), on a ztk canvas, in a terminal, or in an SVG image. `ztcl::typeset book` and `ztcl::typeset markdown` lay out Markdown into the pages of a PDF document.

> [!NOTE]
> `ztcl::typeset` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now. It is in the native builds and in `ztcl-shell.wasm`, the build of the shell and the live examples of the site, and not in `ztcl.wasm`, which stays small.

The module needs no capability. It reads no file: a script reads a font file and gives its bytes to `ztcl::typeset font load`. The work counts toward the compute limit: one unit for each 256 bytes of text, and one for each 64 steps of the line breaker. The guide [Typesetting in Tcl](../typesetting.md) shows the module at work, and [References](../references/typeset.md) lists the papers and the license of the patterns.

<!-- run: native -->
```tcl
package require ztcl::typeset
puts [ztcl::typeset hyphenate typesetting]
puts -nonewline [ztcl::typeset justify "Each line of this paragraph has the same width,\
    because the line breaker looks at the whole paragraph." -width 30]
```

```text
type-set-ting
Each  line  of  this paragraph
has  the  same  width, because
the  line breaker looks at the
whole paragraph.
```

## Commands

### ztcl::typeset break text -width w ?options?

Breaks `text` into lines of width `w` and gives a list with a dict for each line:

| Key | Value |
|---|---|
| `text` | The words of the line, with one space between two words, and the hyphen of a broken word. |
| `words` | A list `x word x word ...`: the x position of each word for the alignment. |
| `width` | The width from the left of the first word to the right of the last word. |
| `ratio` | The adjustment ratio of the spaces: 0 is the natural width, 1 is all of the stretch, -1 is all of the shrink. |
| `hyphen` | 1 when the line ends with a hyphen. |

With `-font`, the widths are in points of that font at `-size`. With no font, the text is on a grid of characters: each character is one unit wide, a space has a whole number of units, and `w` is a count of columns.

| Option | Value |
|---|---|
| `-font font` | A font from `ztcl::typeset font load`. |
| `-size points` | The size of the font. The default is 10. |
| `-method total\|greedy` | `total` (the default) is the total-fit algorithm of Knuth and Plass. `greedy` fills each line as full as it can, as a browser does. |
| `-hyphenate bool` | Hyphenate words (the default is 1). |
| `-indent w` | An indent of the first line. |
| `-tolerance n` | The highest badness of a line (the default is 200; badness is 100 times the cube of the ratio). With no break that fits, the breaker tries again with more stretch. |
| `-align justify\|left\|right\|center` | The x positions. `justify` (the default) fills each line but the last. |
| `-lang en-us` | The language of the patterns. `en-us` is the only one today. |

### ztcl::typeset justify text -width columns ?options?

Gives `text` as justified lines of characters, for a terminal, a README, or a commit message. A blank line in `text` starts a new paragraph. The options are those of `break` with no `-font`.

### ztcl::typeset svg text -width w -font font ?options?

Gives an SVG image of the paragraph. Each line is a `<text>` element, and each word is a `<tspan>` with its own x, so a browser shows the same breaks. `-leading points` sets the distance of two baselines (the default is 1.35 times the size), and `-family name` sets the CSS font family (the default is the family name of the font). The other options are those of `break`.

### ztcl::typeset hyphenate word ?-lang en-us?

Gives `word` with a hyphen at each place where the patterns allow one. A word with fewer than 5 letters, or with a character that is not an ASCII letter, gets no hyphen. Two letters stay before the first hyphen, and three after the last.

### ztcl::typeset pages counts -lines n ?-columns c? ?-gap g?

Places paragraphs on pages. `counts` has the line count of each paragraph, each column has `n` lines, a page has `c` columns (the default is 1), and `g` empty lines go between two paragraphs (the default is 0). The result is a list of pages; a page is a list of columns, and a column is a list of `{paragraph first end}`, where the lines `first` to `end - 1` of that paragraph go in the column. A first line alone at the bottom of a column moves to the next column (no orphan), and a last line alone at the top of a column gets one more line from the column before it (no widow).

### ztcl::typeset font load bytes

Reads a TrueType font from the bytes of the file and gives a handle, such as `font0`. A font with CFF outlines, a font collection, or a variable font gives the error `ZTCL PDF UNSUPPORTED`.

### ztcl::typeset font metrics font size

Gives a dict of the metrics of `font` at `size` points: `family`, `name` (the PostScript name), `ascent`, `descent` (below the baseline, so less than 0), `linegap`, `capheight`, `xheight`, `unitsperem`, `glyphs`, and `fixed`.

### ztcl::typeset font measure font size string

Gives the width of `string` in points, with the kerning and the ligatures of the font.

### ztcl::typeset markdown doc text -fonts dict ?-style dict? ?-run prefix?

Lays out the Markdown `text` into new pages of the `ztcl::pdf` document `doc`, and gives a dict of counts: `pages`, `lines`, `hyphens`, `overfull` (lines wider than the text), `loose` (lines with a ratio above 1), `code_wide` (code lines wider than the text), `checked` (examples that ran), `widest_code`, and `messages` (a list of text lines: failed examples, unknown cross references, and wide code). The Markdown has headings, paragraphs, emphasis, code, links, lists, code blocks, block quotes, and these additions:

- `> [!NOTE]`, `> [!HINT]`, `> [!WARNING]`, and `> [!MISSING]` start an aside with a label.
- `{#id}` at the end of a heading names it, and `[](#id)` is a cross reference with the number of the target, such as "Section 13.2".
- `{^term}` is an entry of the index. The index pages come after the text.
- A code block with the info string `tcl run` or `sh run` runs through the command prefix of `-run`, which gets the language and the code and gives the output. A `tcl run` block compares its output with the `output` block after it, and a `sh run` block compares the output of each `$ ` line with the lines after it. Add `glob` to the info string to make `*` match any text. A difference goes in `messages`.

`-fonts` maps the faces `serif`, `italic`, `bold`, `bolditalic`, `sans`, `sansbold`, `mono`, and `monobold` to fonts of `doc` (from `ztcl::pdf font`). Only `serif` is needed: each other face falls back to a near face. `-style` changes the page: `page_w`, `page_h`, `inner`, `outer`, `top` (to the first baseline), `lines` (on a page), `leading`, `size`, `indent`, `code_size`, `code_leading`, `code_pad`, `mono_scale`, `h1_size`, `h2_size`, `h3_size`, `head_size`, `tolerance`, `hyphen_penalty`, `first_folio`, and `chapter_word`. The sizes are in points.

### ztcl::typeset book doc chapters -fonts dict ?-style dict? ?-run prefix?

The same as `markdown` for a list of chapters. Each chapter is a list `{name number text}`: the name for the messages, the chapter number (0 for none), and the Markdown. Each chapter starts on a new page, and the cross references work across chapters. The book of ztcl (`book/build.tcl`, `zig build book`) uses this command.

## Errors

| Code | Cause |
|---|---|
| `ZTCL TYPESET HANDLE` | No font has that handle. |
| `ZTCL TYPESET LANG` | No patterns for that language. |
| `ZTCL TYPESET FONTS` | `-fonts` has no `serif` key. |
| `ZTCL PDF FONT` | The bytes are not a valid TrueType font. |
| `ZTCL PDF UNSUPPORTED` | The font has a form that the module does not read. |
