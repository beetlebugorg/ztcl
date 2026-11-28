# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::pdf {
    area ztcl
    since TODO
    synopsis {ztcl::pdf subcommand ?arg ...?}
    summary {Makes a PDF document: pages, text in embedded TrueType fonts, rectangles, lines, images, links, named places, the outline, and the document information.}
    description {Makes a PDF document: pages, text in embedded TrueType fonts, rectangles, lines, images, links, named places, the outline, and the document information.}
    page {modules/pdf.md}
    subcommand create {
        synopsis {create ?-compress bool?}
        summary {Makes a document and gives its handle.}
        description {Makes a document and gives its handle.}
    }
    subcommand font {
        synopsis {font doc bytes}
        summary {Adds a TrueType font and gives its number.}
        description {Adds a TrueType font and gives its number.}
    }
    subcommand page {
        synopsis {page doc ?width height?}
        summary {Adds a page and gives its number.}
        description {Adds a page and gives its number. The default is A4.}
    }
    subcommand text {
        synopsis {text doc page font size x y string ?-color rgb? ?-ligatures bool?}
        summary {Shows text and gives its width.}
        description {Shows text and gives its width.}
    }
    subcommand measure {
        synopsis {measure doc font size string}
        summary {Gives the width of a string in points.}
        description {Gives the width of a string in points.}
    }
    subcommand rect {
        synopsis {rect doc page x y width height ?-fill rgb?}
        summary {Fills a rectangle.}
        description {Fills a rectangle.}
    }
    subcommand line {
        synopsis {line doc page x0 y0 x1 y1 ?-width w? ?-color rgb?}
        summary {Strokes a line.}
        description {Strokes a line.}
    }
    subcommand image {
        synopsis {image doc bytes}
        summary {Adds a PNG or JPEG image and gives {number width height}.}
        description {Adds a PNG or JPEG image and gives {number width height}.}
    }
    subcommand place {
        synopsis {place doc page image x y width height}
        summary {Shows an image in a rectangle.}
        description {Shows an image in a rectangle.}
    }
    subcommand link {
        synopsis {link doc page x0 y0 x1 y1 -uri url|-dest name}
        summary {Makes a rectangle a link.}
        description {Makes a rectangle a link.}
    }
    subcommand dest {
        synopsis {dest doc name page x y}
        summary {Names a place for a link.}
        description {Names a place for a link.}
    }
    subcommand outline {
        synopsis {outline doc title level page y}
        summary {Adds an entry to the outline.}
        description {Adds an entry to the outline.}
    }
    subcommand info {
        synopsis {info doc key value}
        summary {Sets the Title, Author, Subject, or Keywords.}
        description {Sets the Title, Author, Subject, or Keywords.}
    }
    subcommand bytes {
        synopsis {bytes doc}
        summary {Gives the bytes of the PDF file.}
        description {Gives the bytes of the PDF file.}
    }
    subcommand pages {
        synopsis {pages doc}
        summary {Gives the count of pages.}
        description {Gives the count of pages.}
    }
    subcommand delete {
        synopsis {delete doc}
        summary {Frees the document.}
        description {Frees the document.}
    }
}
