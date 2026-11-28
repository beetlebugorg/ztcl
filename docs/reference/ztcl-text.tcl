# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::text {
    area ztcl
    since TODO
    synopsis {ztcl::text subcommand ?arg ...?}
    summary {Cuts a string into grapheme clusters, words, or sentences by the rules of Unicode 18.0.0 (UAX #29), and gives its display width in columns (UAX #11 and UTS #51).}
    description {Cuts a string into grapheme clusters, words, or sentences by the rules of Unicode 18.0.0 (UAX #29), and gives its display width in columns (UAX #11 and UTS #51). Load it with `package require ztcl::text`.}
    cost {One compute unit for each 4,096 bytes of the string.}
    page {modules/text.md}
    names {ztcl::text::graphemes ztcl::text::words ztcl::text::sentences ztcl::text::width ztcl::text::bounds}
    example {package require ztcl::text} TODO
    example {llength [ztcl::text graphemes "e\u0301\U1F44D\U1F3FD"]} 2
    example {ztcl::text words "Hello, world."} {Hello world}
    example {ztcl::text width "\u4E2D\u6587 ok"} 7
    example {ztcl::text bounds "ab\u0301c"} {0 1 3 4}
    subcommand graphemes {
        synopsis {graphemes STRING}
        summary {The list of the grapheme clusters: the characters that a user sees, such as an emoji with a skin tone or a letter with accents.}
        description {The list of the grapheme clusters: the characters that a user sees, such as an emoji with a skin tone or a letter with accents.}
    }
    subcommand words {
        synopsis {words ?-all? STRING}
        summary {The list of the word segments that have a letter or a number.}
        description {The list of the word segments that have a letter or a number. With `-all`, each segment, so `join` of the list gives the string again.}
    }
    subcommand sentences {
        synopsis {sentences STRING}
        summary {The list of the sentences, each with its spaces and line end.}
        description {The list of the sentences, each with its spaces and line end.}
    }
    subcommand width {
        synopsis {width ?-ambiguous narrow|wide? STRING}
        summary {The count of columns of the string in a terminal or a monospace font.}
        description {The count of columns of the string in a terminal or a monospace font. The East Asian Ambiguous characters are 1 column, or 2 with `-ambiguous wide`.}
    }
    subcommand bounds {
        synopsis {bounds ?-unit grapheme|word|sentence? STRING}
        summary {The list of the character index of each boundary, from 0 to the length of the string.}
        description {The list of the character index of each boundary, from 0 to the length of the string.}
    }
}
