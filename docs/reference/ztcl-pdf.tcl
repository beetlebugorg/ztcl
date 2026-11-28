# The command reference: ztcl::pdf. The format is in
# docs/dev/reference-format.md.

command ztcl::pdf {
    area ztcl
    since 1.0.0-beta.1
    flags {--allow file,channels}
    setup {
        package require ztcl::pdf
        proc slurp {path} { set f [open $path rb]; set d [read $f]; close $f; return $d }
        # A font of the repository: the examples run in zig-out/refdoc-run/N.
        set serif [slurp ../../../book/fonts/SourceSans3-Regular.ttf]
        # A PNG of 2 by 1 gray pixels.
        set png [binary decode hex 89504e470d0a1a0a0000000d4948445200000002000000010800000000d14920560000000b49444154789c6360f80f000102010042bebc680000000049454e44ae426082]
        set d [ztcl::pdf create]
        set f [ztcl::pdf font $d $serif]
        set p [ztcl::pdf page $d]
    }
    synopsis {ztcl::pdf SUBCOMMAND ?ARG ...?}
    summary {Makes a PDF document: pages, text in embedded TrueType fonts, rectangles, lines, images, links, named places, the outline, and the document information.}
    description {
        The commands of PDF files: pages, text in embedded TrueType fonts with kerning and ligatures, rectangles and lines, PNG and JPEG images, links to URLs and to places in the document, the outline (the bookmarks of a reader), and the document information. With `ztcl::typeset`, the same document gets justified paragraphs, hyphenation, and books from Markdown. The guide [PDF documents](pdf/) has five complete programs.

        Load the module with `package require ztcl::pdf`. It needs no capability and reads or writes no file: a script reads the bytes of each font and image, and writes the bytes of the PDF. It is in the native builds and in `ztcl-shell.wasm`, and `ztcl.wasm` leaves it out.

        The coordinates are in points (1/72 inch) from the lower-left corner of the page. A text position is the left end of the baseline. A color is a list of three numbers from 0 to 1, such as `{0.1 0.2 0.5}`. Each font goes into the file as a subset with only the glyphs that the document uses, with the widths and a map back to Unicode, so a reader can copy and search the text. The streams are compressed with Flate, and the output is a PDF 1.7 file.

        The work counts toward the compute limit: one unit for each 4,096 bytes of a font, an image, or the output, and one unit for each 256 bytes of text. A font or an image has at most 64 MiB, and a document has at most 100,000 pages.

        `create` gives a handle such as `pdf0`, and the first argument of each other subcommand is a handle. The handle is looked up before the name of the subcommand, so an unknown subcommand gives the error of the handle or of a wrong count, and with a live handle `-errorcode NONE` ([issue 760](https://github.com/beetlebugorg/ztcl/issues/760)). An error of the module has a code that starts with `ZTCL PDF`: `HANDLE`, `INDEX`, `FONT`, `IMAGE`, `UNSUPPORTED`, `DEST`, `NUMBER`, `COLOR`, and `SIZE`.

        The examples of this page run with `--allow file,channels` to read a font of the repository. The setup makes the document `$d` with the font `$f` and the page `$p`, and the bytes `$serif` of the font and `$png` of a small image.
    }
    returns {The result of the subcommand.}
    page modules/pdf/
    see {ztcl::typeset binary}
    example {
        ztcl::pdf text $d $p $f 24 72 760 "Hello, PDF"
        ztcl::pdf outline $d Hello 1 $p 800
        set b [ztcl::pdf bytes $d]
        list [string range $b 0 7] [string trim [string range $b end-5 end]]
    } {%PDF-1.7 %%EOF}
    error {ztcl::pdf bogus x} {can not find document "x"} {ZTCL PDF HANDLE}
    error {ztcl::pdf bogus $d} {unknown subcommand "bogus": must be create|font|page|text|measure|rect|line|image|place|link|dest|outline|info|bytes|pages|delete ?arg ...?} NONE
    error {ztcl::pdf} {wrong # args: should be "ztcl::pdf create|font|page|text|measure|rect|line|image|place|link|dest|outline|info|bytes|pages|delete ?arg ...?"} {TCL WRONGARGS}

    subcommand create {
        synopsis {ztcl::pdf create ?-compress BOOL?}
        summary {Makes a new document and gives its handle.}
        description {Makes a new empty document and gives its handle, such as `pdf0`.}
        returns {The handle of the document.}
        see {{ztcl::pdf delete} {ztcl::pdf bytes}}
        example {
            set n [ztcl::pdf create]
            list [string match pdf* $n] [ztcl::pdf pages $n]
        } {1 0}
        error {ztcl::pdf create -bogus 1} {unknown option "-bogus": the options are -compress} NONE
        error {ztcl::pdf create -compress} {wrong # args: should be "ztcl::pdf create ?-compress bool?"} {TCL WRONGARGS}
        option -compress {
            value BOOL
            type boolean
            default 1
            summary {Turns the compression of the streams on or off.}
            description {`-compress 0` writes the streams with no compression, to read the file in a text editor. Only `0` turns it off: `no`, `false`, and a word that is no boolean give compression, with no error ([issue 760](https://github.com/beetlebugorg/ztcl/issues/760)).}
            example {
                set n [ztcl::pdf create -compress 0]
                set nf [ztcl::pdf font $n $serif]
                set np [ztcl::pdf page $n]
                ztcl::pdf text $n $np $nf 12 72 700 Hi
                ztcl::pdf info $n Author Me
                set b [ztcl::pdf bytes $n]
                list [string match "*/Author (Me)*" $b] [string match *SourceSans3* $b]
            } {1 1}
            noerrors {Each value is accepted (issue 760).}
        }
    }

    subcommand font {
        synopsis {ztcl::pdf font DOC BYTES}
        summary {Adds a TrueType font and gives its number.}
        description {Adds a TrueType font from the bytes of the file and gives its number in the document, from 0. A font with CFF outlines, a font collection, or a variable font gives `ZTCL PDF UNSUPPORTED`.}
        returns {The number of the font.}
        see {{ztcl::pdf text} {ztcl::typeset font}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument BYTES {
            type {byte string}
            summary {The bytes of a `.ttf` file.}
        }
        example {list $f [ztcl::pdf font $d $serif]} {0 1}
        error {ztcl::pdf font $d abc} {the font is not a valid TrueType font} {ZTCL PDF FONT}
        error {ztcl::pdf font nope abc} {can not find document "nope"} {ZTCL PDF HANDLE}
    }

    subcommand page {
        synopsis {ztcl::pdf page DOC ?WIDTH HEIGHT?}
        summary {Adds a page and gives its number.}
        description {Adds a page and gives its number, from 0. The default size is A4, 595.276 by 841.89 points, and US Letter is 612 by 792. A side is from 1 to 14,400 points.}
        returns {The number of the page.}
        see {{ztcl::pdf pages}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument WIDTH {
            type number
            optional
            summary {The width in points.}
        }
        argument HEIGHT {
            type number
            optional
            summary {The height in points.}
        }
        example {list $p [ztcl::pdf page $d 612 792] [ztcl::pdf pages $d]} {0 1 2}
        error {ztcl::pdf page $d -1 5} {a page side is from 1 to 14400 points} {ZTCL PDF NUMBER}
        error {ztcl::pdf page $d 1e30 5} {the number 1000000000000000000000000000000 is outside the range of a PDF} {ZTCL PDF NUMBER}
        error {ztcl::pdf page $d x 5} {expected number but got "x"} NONE
        error {ztcl::pdf page $d 612} {wrong # args: should be "ztcl::pdf page doc ?width height?"} {TCL WRONGARGS}
    }

    subcommand text {
        synopsis {ztcl::pdf text DOC PAGE FONT SIZE X Y STRING ?-color RGB? ?-ligatures BOOL?}
        summary {Shows text and gives its width.}
        description {Shows STRING in FONT at SIZE points, with its left baseline at (X, Y), and gives its width in points, with the kerning of the font. The width has the digits of a 32-bit number, where `measure` rounds it ([issue 760](https://github.com/beetlebugorg/ztcl/issues/760)).}
        returns {The width in points.}
        see {{ztcl::pdf measure} {ztcl::pdf font}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument PAGE {
            type integer
            summary {A page number from `page`.}
        }
        argument FONT {
            type integer
            summary {A font number from `font`.}
        }
        argument SIZE {
            type number
            summary {The size in points.}
        }
        argument X {
            type number
            summary {The x of the left end of the baseline.}
        }
        argument Y {
            type number
            summary {The y of the baseline.}
        }
        argument STRING {
            type string
            summary {The text.}
        }
        example {format %.3f [ztcl::pdf text $d $p $f 24 72 760 "Hello, PDF"]} 103.536
        error {ztcl::pdf text $d 9 $f 10 72 700 x} {there is no page 9} {ZTCL PDF INDEX}
        error {ztcl::pdf text $d $p 9 10 72 700 x} {there is no font 9} {ZTCL PDF INDEX}
        error {ztcl::pdf text $d $p $f 10 72 700 x -bogus 1} {unknown option "-bogus": the options are -color, -ligatures} NONE
        error {ztcl::pdf text $d $p $f 10 72 700} {wrong # args: should be "ztcl::pdf text doc page font size x y string ?-color rgb? ?-ligatures bool?"} {TCL WRONGARGS}
        option -color {
            value RGB
            type {list of 3 numbers}
            default {0 0 0}
            summary {Gives the color of the text.}
            description {A list of three numbers from 0 to 1. A number above 1 is not checked ([issue 760](https://github.com/beetlebugorg/ztcl/issues/760)).}
            example {format %.2f [ztcl::pdf text $d $p $f 10 72 700 x -color {1 0 0}]} 4.46
            error {ztcl::pdf text $d $p $f 10 72 700 x -color red} {a color is a list of 3 numbers from 0 to 1} {ZTCL PDF COLOR}
        }
        option -ligatures {
            value BOOL
            type boolean
            default 1
            summary {Turns the ligatures of the font on or off.}
            description {With 1 the text has the `fi`, `fl`, and other ligatures of the font, so `office` is narrower than with 0.}
            example {
                list [format %.2f [ztcl::pdf text $d $p $f 10 72 700 office]] [format %.2f [ztcl::pdf text $d $p $f 10 72 700 office -ligatures 0]]
            } {22.94 23.01}
            noerrors {The value is read as a boolean.}
        }
    }

    subcommand measure {
        synopsis {ztcl::pdf measure DOC FONT SIZE STRING}
        summary {Gives the width of a string in points.}
        description {Gives the width of STRING in FONT at SIZE points, with the kerning and the ligatures of `text`.}
        returns {The width in points.}
        see {{ztcl::pdf text} {ztcl::typeset font}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument FONT {
            type integer
            summary {A font number from `font`.}
        }
        argument SIZE {
            type number
            summary {The size in points.}
        }
        argument STRING {
            type string
            summary {The text.}
        }
        example {ztcl::pdf measure $d $f 24 "Hello, PDF"} 103.536
        example {list [ztcl::pdf measure $d $f 10 A] [ztcl::pdf measure $d $f 10 AV]} {5.43 10.44}
        error {ztcl::pdf measure $d 9 10 x} {there is no font 9} {ZTCL PDF INDEX}
    }

    subcommand rect {
        synopsis {ztcl::pdf rect DOC PAGE X Y WIDTH HEIGHT ?-fill RGB?}
        summary {Fills a rectangle.}
        description {Fills the rectangle with its lower-left corner at (X, Y). The default color is black.}
        returns {An empty string.}
        see {{ztcl::pdf line}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument PAGE {
            type integer
            summary {A page number.}
        }
        example {ztcl::pdf rect $d $p 10 10 100 50} {}
        error {ztcl::pdf rect $d $p 10 10 100} {wrong # args: should be "ztcl::pdf rect doc page x y width height ?-fill rgb?"} {TCL WRONGARGS}
        error {ztcl::pdf rect $d 9 10 10 100 50} {there is no page 9} {ZTCL PDF INDEX}
        option -fill {
            value RGB
            type {list of 3 numbers}
            default {0 0 0}
            summary {Gives the color of the rectangle.}
            description {A list of three numbers from 0 to 1.}
            example {ztcl::pdf rect $d $p 10 10 100 50 -fill {0 0 1}} {}
            error {ztcl::pdf rect $d $p 10 10 100 50 -fill blue} {a color is a list of 3 numbers from 0 to 1} {ZTCL PDF COLOR}
        }
    }

    subcommand line {
        synopsis {ztcl::pdf line DOC PAGE X0 Y0 X1 Y1 ?-width W? ?-color RGB?}
        summary {Strokes a line.}
        description {Strokes a line from (X0, Y0) to (X1, Y1).}
        returns {An empty string.}
        see {{ztcl::pdf rect}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument PAGE {
            type integer
            summary {A page number.}
        }
        example {ztcl::pdf line $d $p 0 0 100 100} {}
        error {ztcl::pdf line $d 9 0 0 100 100} {there is no page 9} {ZTCL PDF INDEX}
        option -width {
            value W
            type number
            default 1
            summary {Gives the width of the line in points.}
            description {The width of the stroke. A negative width is not checked ([issue 760](https://github.com/beetlebugorg/ztcl/issues/760)).}
            example {ztcl::pdf line $d $p 0 0 100 100 -width 2} {}
            error {ztcl::pdf line $d $p 0 0 100 100 -width x} {expected number but got "x"} NONE
        }
        option -color {
            value RGB
            type {list of 3 numbers}
            default {0 0 0}
            summary {Gives the color of the line.}
            description {A list of three numbers from 0 to 1.}
            example {ztcl::pdf line $d $p 0 0 100 100 -color {0.5 0.5 0.5}} {}
            error {ztcl::pdf line $d $p 0 0 100 100 -color gray} {a color is a list of 3 numbers from 0 to 1} {ZTCL PDF COLOR}
        }
    }

    subcommand image {
        synopsis {ztcl::pdf image DOC BYTES}
        summary {Adds a PNG or JPEG image and gives its number and size.}
        description {Adds a PNG or JPEG image and gives the list `NUMBER WIDTH HEIGHT`, with the size in pixels. A PNG has 8 bits for each sample and no interlace, and it can be gray, RGB, a palette, or have an alpha channel. A JPEG goes into the file with no change.}
        returns {A list of the number, the width, and the height.}
        see {{ztcl::pdf place}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument BYTES {
            type {byte string}
            summary {The bytes of a PNG or JPEG file.}
        }
        example {ztcl::pdf image $d $png} {0 2 1}
        error {ztcl::pdf image $d abc} {the image is not a valid PNG or JPEG file} {ZTCL PDF IMAGE}
        error {
            # A 16-bit PNG of 1 pixel.
            ztcl::pdf image $d [binary decode hex 89504e470d0a1a0a0000000d49484452000000010000000110000000006aee47160000000b49444154789c636060000000030001b8ad3a630000000049454e44ae426082]
        } {the file has a form that ztcl::pdf does not read (CFF outlines, a font collection, a variable font, or an interlaced or 16-bit PNG)} {ZTCL PDF UNSUPPORTED}
    }

    subcommand place {
        synopsis {ztcl::pdf place DOC PAGE IMAGE X Y WIDTH HEIGHT}
        summary {Shows an image in a rectangle.}
        description {Shows the image IMAGE of the document in the rectangle with its lower-left corner at (X, Y). An image can show on many pages and goes into the file once.}
        returns {An empty string.}
        see {{ztcl::pdf image}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument IMAGE {
            type integer
            summary {An image number from `image`.}
        }
        example {
            set i [lindex [ztcl::pdf image $d $png] 0]
            ztcl::pdf place $d $p $i 10 10 20 10
        } {}
        error {ztcl::pdf place $d $p 9 10 10 20 10} {there is no image 9} {ZTCL PDF INDEX}
    }

    subcommand link {
        synopsis {ztcl::pdf link DOC PAGE X0 Y0 X1 Y1 -uri URL}
        synopsis {ztcl::pdf link DOC PAGE X0 Y0 X1 Y1 -dest NAME}
        summary {Makes a rectangle a link to a URL or to a named place.}
        description {Makes the rectangle of the page a link: with `-uri` to a URL, and with `-dest` to a named place of the document. A name with no `dest` is an error of `bytes`.}
        returns {An empty string.}
        see {{ztcl::pdf dest}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument PAGE {
            type integer
            summary {A page number.}
        }
        example {ztcl::pdf link $d $p 0 0 10 10 -uri https://example.com/} {}
        example {
            ztcl::pdf link $d $p 0 0 10 10 -dest intro
            ztcl::pdf dest $d intro $p 72 800
            string range [ztcl::pdf bytes $d] 0 7
        } %PDF-1.7
        error {
            ztcl::pdf link $d $p 0 0 10 10 -dest nowhere
            ztcl::pdf bytes $d
        } {a link names a target that the document does not have} {ZTCL PDF DEST}
        error {ztcl::pdf link $d $p 0 0 10 10} {wrong # args: should be "ztcl::pdf link doc page x0 y0 x1 y1 -uri url|-dest name"} {TCL WRONGARGS}
        error {ztcl::pdf link $d $p 0 0 10 10 -bogus x} {wrong # args: should be "ztcl::pdf link doc page x0 y0 x1 y1 -uri url|-dest name"} {TCL WRONGARGS}
    }

    subcommand dest {
        synopsis {ztcl::pdf dest DOC NAME PAGE X Y}
        summary {Names a place for a link.}
        description {Names the place (X, Y) of the page, for `link -dest`.}
        returns {An empty string.}
        see {{ztcl::pdf link} {ztcl::pdf outline}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument NAME {
            type string
            summary {The name of the place.}
        }
        example {ztcl::pdf dest $d intro $p 72 800} {}
        error {ztcl::pdf dest $d intro 9 72 800} {there is no page 9} {ZTCL PDF INDEX}
    }

    subcommand outline {
        synopsis {ztcl::pdf outline DOC TITLE LEVEL PAGE Y}
        summary {Adds an entry to the outline.}
        description {Adds an entry to the outline that goes to the height Y of the page. Level 1 is the top level, and an entry of level 2 after it is its child. A level is 1 to 16.}
        returns {An empty string.}
        see {{ztcl::pdf dest}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument TITLE {
            type string
            summary {The text of the entry.}
        }
        argument LEVEL {
            type integer
            summary {The level, 1 for the top.}
        }
        example {
            ztcl::pdf outline $d Hello 1 $p 800
            ztcl::pdf outline $d Child 2 $p 700
        } {}
        error {ztcl::pdf outline $d Bad 0 $p 700} {the level 0 is outside 1 to 16} {ZTCL PDF INDEX}
    }

    subcommand info {
        synopsis {ztcl::pdf info DOC KEY VALUE}
        summary {Sets the title, the author, the subject, or the keywords of the document.}
        description {Sets the entry KEY of the document information: `Title`, `Author`, `Subject`, or `Keywords`. A key in other letter case, such as `title`, is the same key.}
        returns {An empty string.}
        see {{ztcl::pdf bytes}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        argument KEY {
            type {Title, Author, Subject, or Keywords}
            summary {The entry to set.}
        }
        argument VALUE {
            type string
            summary {The text of the entry.}
        }
        example {ztcl::pdf info $d Title "A report"} {}
        error {ztcl::pdf info $d Bogus x} {unknown key "Bogus": the keys are Title, Author, Subject, and Keywords} NONE
    }

    subcommand bytes {
        synopsis {ztcl::pdf bytes DOC}
        summary {Gives the bytes of the PDF file.}
        description {Gives the bytes of the PDF file. Write them to a channel with the `binary` translation, as `open $path wb` gives.}
        returns {A byte string.}
        see {open {ztcl::pdf create}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        example {
            set out [open out.pdf wb]
            puts -nonewline $out [ztcl::pdf bytes $d]
            close $out
            expr {[file size out.pdf] == [string length [ztcl::pdf bytes $d]]}
        } 1
        error {ztcl::pdf bytes $d x} {wrong # args: should be "ztcl::pdf bytes doc"} {TCL WRONGARGS}
    }

    subcommand pages {
        synopsis {ztcl::pdf pages DOC}
        summary {Gives the count of pages.}
        description {Gives the count of the pages of the document.}
        returns {An integer.}
        see {{ztcl::pdf page}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        example {ztcl::pdf pages $d} 1
        error {ztcl::pdf pages nope} {can not find document "nope"} {ZTCL PDF HANDLE}
    }

    subcommand delete {
        synopsis {ztcl::pdf delete DOC}
        summary {Frees a document.}
        description {Frees the document, and the handle is then invalid.}
        returns {An empty string.}
        see {{ztcl::pdf create}}
        argument DOC {
            type handle
            summary {A handle from `create`.}
        }
        example {
            ztcl::pdf delete $d
            catch {ztcl::pdf pages $d}
        } 1
        error {
            ztcl::pdf delete $d
            ztcl::pdf delete $d
        } {can not find document "pdf0"} {ZTCL PDF HANDLE}
    }
}
