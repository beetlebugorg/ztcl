# Module ztcl::pdf

`ztcl::pdf` makes PDF files: pages, text in embedded TrueType fonts with kerning and ligatures, rectangles and lines, PNG and JPEG images, links to URLs and to places in the document, the outline (the bookmarks of a reader), and the document information. Use it for reports, invoices, letters, labels, and printed documentation. With `ztcl::typeset`, the same document gets justified paragraphs, hyphenation, and whole books from Markdown.

> [!NOTE]
> `ztcl::pdf` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now. It is in the native builds and in `ztcl-shell.wasm`, the build of the shell and the live examples of the site, and not in `ztcl.wasm`, which stays small.

The module needs no capability and reads or writes no file. A script reads the bytes of each font and image, and writes the bytes of the PDF:

```tcl
package require ztcl::pdf
proc slurp {path} {
    set f [open $path rb]; set data [read $f]; close $f
    return $data
}
set doc [ztcl::pdf create]
set font [ztcl::pdf font $doc [slurp book/fonts/SourceSerif4-Regular.ttf]]
set page [ztcl::pdf page $doc 595.276 841.89]          ;# A4, in points
ztcl::pdf text $doc $page $font 24 72 760 "Hello, PDF"
ztcl::pdf outline $doc "Hello" 1 $page 800
set f [open hello.pdf wb]
puts -nonewline $f [ztcl::pdf bytes $doc]
close $f
ztcl::pdf delete $doc
```

```sh
$ ztcl --allow channels,file hello.tcl
```

The guide [PDF documents](../pdf.md) has five complete programs: an invoice, a report with a table and a chart, a letter, a manual with an outline and links, and a sheet of labels.

The coordinates are in points (1/72 inch) from the lower-left corner of the page, as in PDF. A text position is the left end of the baseline. A color is a list of three numbers from 0 to 1: `{0.1 0.2 0.5}`.

Each font goes into the file as a subset with only the glyphs that the document uses, with the widths and a map back to Unicode, so a reader can copy and search the text. The streams are compressed with Flate. The output is a PDF 1.7 file. PDF/A is not in this version.

The work counts toward the compute limit: one unit for each 4,096 bytes of a font, an image, or the output, and one unit for each 256 bytes of text. A font or an image has at most 64 MiB, and a document has at most 100,000 pages.

## Commands

### ztcl::pdf create ?-compress bool?

Makes a new document and gives its handle, such as `pdf0`. `-compress 0` writes the streams with no compression, to read the file in a text editor.

### ztcl::pdf font doc bytes

Adds a TrueType font from the bytes of the file and gives its number in the document. A font with CFF outlines, a font collection, or a variable font gives the error `ZTCL PDF UNSUPPORTED`.

### ztcl::pdf page doc ?width height?

Adds a page and gives its number, from 0. The default size is A4 (595.276 by 841.89 points). US Letter is 612 by 792.

### ztcl::pdf text doc page font size x y string ?-color rgb? ?-ligatures bool?

Shows `string` with its left baseline at (x, y) and gives its width in points. The text has the kerning of the font, and its `fi`, `fl`, and other ligatures unless `-ligatures 0`.

### ztcl::pdf measure doc font size string

Gives the width of `string` in points, with the same kerning and ligatures as `text`.

### ztcl::pdf rect doc page x y width height ?-fill rgb?

Fills a rectangle. The default color is black.

### ztcl::pdf line doc page x0 y0 x1 y1 ?-width w? ?-color rgb?

Strokes a line. The default width is 1 point.

### ztcl::pdf image doc bytes

Adds a PNG or JPEG image and gives the list `{number width height}`, with the size in pixels. A PNG has 8 bits for each sample and no interlace; it can be gray, RGB, a palette, or have an alpha channel. A JPEG goes into the file with no change.

### ztcl::pdf place doc page image x y width height

Shows an image of the document in the rectangle with its lower-left corner at (x, y).

### ztcl::pdf link doc page x0 y0 x1 y1 -uri url
### ztcl::pdf link doc page x0 y0 x1 y1 -dest name

Makes the rectangle a link: to a URL, or to a named place of the document. A name with no `dest` is an error of `bytes`.

### ztcl::pdf dest doc name page x y

Names a place of the document, for `link -dest`.

### ztcl::pdf outline doc title level page y

Adds an entry to the outline. Level 1 is the top level, and an entry of level 2 after it is its child. The entry goes to the height `y` of the page.

### ztcl::pdf info doc key value

Sets the `Title`, `Author`, `Subject`, or `Keywords` of the document.

### ztcl::pdf bytes doc

Gives the bytes of the PDF file. Write them to a channel with the `binary` translation (`open $path wb`).

### ztcl::pdf pages doc

Gives the count of pages.

### ztcl::pdf delete doc

Frees the document.

## Errors

| Code | Cause |
|---|---|
| `ZTCL PDF HANDLE` | No document has that handle. |
| `ZTCL PDF INDEX` | No page, font, or image has that number. |
| `ZTCL PDF FONT` | The bytes are not a valid TrueType font. |
| `ZTCL PDF IMAGE` | The bytes are not a valid PNG or JPEG file. |
| `ZTCL PDF UNSUPPORTED` | The file has a form that the module does not read. |
| `ZTCL PDF DEST` | A link names a place with no `dest`. |
| `ZTCL PDF NUMBER` | A number is outside the range of a PDF. |
| `ZTCL PDF SIZE` | The data has more than 64 MiB, or the document more than 100,000 pages. |
