# The command reference: ztcl::text. The format is in
# docs/dev/reference-format.md.

command ztcl::text {
    area ztcl
    since 1.0.0-beta.1
    setup {package require ztcl::text}
    synopsis {ztcl::text SUBCOMMAND ?ARG ...?}
    summary {Cuts a string into grapheme clusters, words, or sentences, and gives its display width in columns.}
    description {
        The commands for the units of text that a reader sees. Tcl counts code points, and a user sees one character in `e` with a combining accent, in a flag of two regional indicators, and in a family emoji of several code points. `graphemes`, `words`, and `sentences` cut a string by the rules of Unicode 18.0.0 (UAX #29), `bounds` gives the indexes of the cuts, and `width` gives the count of columns of a string (UAX #11 and UTS #51).

        Load the module with `package require ztcl::text`. It needs no capability. Each subcommand is also the command `ztcl::text::NAME`, such as `ztcl::text::width`, and a unique prefix of a subcommand is the subcommand.

        The last argument of each subcommand is the string, so `ztcl::text width -ambiguous` gives the width of the string `-ambiguous`. The `-grapheme` forms of `string length`, `string index`, `string range`, `string reverse`, and `split` count in grapheme clusters with no `package require`.
    }
    returns {The result of the subcommand.}
    cost {One compute unit for each 4,096 bytes of the string.}
    page modules/text/
    names {ztcl::text::graphemes ztcl::text::words ztcl::text::sentences ztcl::text::width ztcl::text::bounds}
    see {{string length} split}
    example {llength [ztcl::text graphemes "é\U1F44D\U1F3FD"]} 2
    example {ztcl::text words "Hello, world."} {Hello world}
    example {ztcl::text width "中文 ok"} 7
    example {ztcl::text bounds "ab́c"} {0 1 3 4}
    example {ztcl::text g ab} {a b}
    error {ztcl::text bogus} {unknown or ambiguous subcommand "bogus": must be bounds, graphemes, sentences, width, or words} {TCL LOOKUP SUBCOMMAND bogus}
    error {ztcl::text} {wrong # args: should be "ztcl::text subcommand ?arg ...?"} {TCL WRONGARGS}

    subcommand graphemes {
        synopsis {ztcl::text graphemes STRING}
        summary {Gives the list of the grapheme clusters of a string.}
        description {Gives the list of the extended grapheme clusters of STRING: the characters that a user sees, such as an emoji with a skin tone or a letter with accents. `join` of the list gives STRING again, and an empty STRING gives an empty list.}
        returns {A list of strings.}
        see {{string length} split {ztcl::text bounds}}
        argument STRING {
            type string
            summary {The string to cut.}
        }
        example {llength [ztcl::text graphemes "é\U1F44D\U1F3FD"]} 2
        example {ztcl::text graphemes "abc"} {a b c}
        example {
            set s "é\U1F1FA\U1F1F8x"
            list [string length $s] [llength [ztcl::text graphemes $s]]
        } {5 3}
        example {
            set s "éx"
            string equal [join [ztcl::text graphemes $s] ""] $s
        } 1
        example {ztcl::text graphemes ""} {}
        error {ztcl::text graphemes} {wrong # args: should be "ztcl::text graphemes string"} {TCL WRONGARGS}
        error {ztcl::text graphemes a b} {wrong # args: should be "ztcl::text graphemes string"} {TCL WRONGARGS}
    }

    subcommand words {
        synopsis {ztcl::text words ?-all? STRING}
        summary {Gives the list of the words of a string.}
        description {Gives the word segments of UAX #29 that have a letter or a number. Spaces and punctuation are segments of their own, and only `-all` keeps them. The rules keep `can't`, `e.g`, `3.14`, and `example.com` in one segment.}
        returns {A list of strings.}
        see {{ztcl::text sentences} {ztcl::text bounds} split}
        argument STRING {
            type string
            summary {The string to cut.}
        }
        example {ztcl::text words "Hello, world."} {Hello world}
        example {ztcl::text words "Don't stop: 3.14 is pi."} {Don't stop 3.14 is pi}
        example {ztcl::text words "see example.com, e.g."} {see example.com e.g}
        example {ztcl::text words ""} {}
        error {ztcl::text words} {wrong # args: should be "ztcl::text words ?-all? string"} {TCL WRONGARGS}
        error {ztcl::text words -bogus x} {bad option "-bogus": must be -all} {TCL LOOKUP INDEX option}
        option -all {
            type flag
            summary {Keeps each segment, also the spaces and the punctuation.}
            description {Gives each segment of STRING, so `join` of the list gives STRING again.}
            example {ztcl::text words -all "a, b"} {a , { } b}
            example {join [ztcl::text words -all "Hi, you."] ""} {Hi, you.}
            error {ztcl::text words -- x} {bad option "--": must be -all} {TCL LOOKUP INDEX option}
        }
    }

    subcommand sentences {
        synopsis {ztcl::text sentences STRING}
        summary {Gives the list of the sentences of a string.}
        description {Gives the sentences of UAX #29. Each sentence keeps its closing marks, its spaces, and its line end, so `join` of the list gives STRING again. A period in a number, such as `3.5`, ends no sentence.}
        returns {A list of strings.}
        see {{ztcl::text words} {ztcl::text bounds}}
        argument STRING {
            type string
            summary {The string to cut.}
        }
        example {ztcl::text sentences "It is 3.5 m long. Is it? Yes."} {{It is 3.5 m long. } {Is it? } Yes.}
        example {ztcl::text sentences "a\nb"} "{a\n} b"
        example {ztcl::text sentences ""} {}
        error {ztcl::text sentences} {wrong # args: should be "ztcl::text sentences string"} {TCL WRONGARGS}
    }

    subcommand width {
        synopsis {ztcl::text width ?-ambiguous narrow|wide? STRING}
        summary {Gives the count of columns of a string in a terminal or a monospace font.}
        description {
            Each grapheme cluster has the largest width of its code points, plus the width of each spacing mark and each conjunct consonant in it:

            - marks, format characters except U+00AD, controls such as `\t`, default ignorables, and the medial and final jamo of Hangul are 0 columns;
            - the East Asian Wide and Fullwidth characters, and emoji with emoji presentation, are 2 columns;
            - the East Asian Ambiguous characters, such as `±` and the Greek letters, are 1 column, or 2 with `-ambiguous wide`;
            - each other code point is 1 column.

            U+FE0F after an emoji makes the cluster 2 columns, and a flag of two regional indicators is 2 columns. The widths equal the cursor moves of the terminal of `ztcl::vt` with grapheme clusters on (mode 2027).
        }
        returns {An integer.}
        see {{ztcl::text graphemes} {string length}}
        argument STRING {
            type string
            summary {The string to measure.}
        }
        example {ztcl::text width "ab中"} 4
        example {ztcl::text width "❤️ é"} 4
        example {ztcl::text width "\U1F1FA\U1F1F8"} 2
        example {ztcl::text width "a\tb"} 2
        example {ztcl::text width ""} 0
        error {ztcl::text width} {wrong # args: should be "ztcl::text width ?-ambiguous narrow|wide? string"} {TCL WRONGARGS}
        error {ztcl::text width -x a} {wrong # args: should be "ztcl::text width ?-ambiguous narrow|wide? string"} {TCL WRONGARGS}
        option -ambiguous {
            value WIDTH
            type {narrow or wide}
            default narrow
            values {narrow wide}
            summary {Gives the width of the East Asian Ambiguous characters.}
            description {`narrow` counts each East Asian Ambiguous character as 1 column, and `wide` as 2, as a terminal set for East Asian text does. The name of the option has no short form.}
            example {ztcl::text width -ambiguous wide "±"} 2
            example {ztcl::text width -ambiguous narrow "±"} 1
            error {ztcl::text width -ambiguous big a} {bad value "big": must be narrow or wide} {TCL LOOKUP INDEX value}
            error {ztcl::text width -amb wide a} {bad option "-amb": must be -ambiguous} {TCL LOOKUP INDEX option}
        }
    }

    subcommand bounds {
        synopsis {ztcl::text bounds ?-unit grapheme|word|sentence? STRING}
        summary {Gives the character index of each boundary of a string.}
        description {Gives the index of each boundary of a unit, from 0 to the length of STRING. The indexes count code points, as `string index` and `string range` do, so a unit runs from one index to the next index minus 1. An empty STRING gives `0`.}
        returns {A list of integers.}
        see {{ztcl::text graphemes} {string range}}
        argument STRING {
            type string
            summary {The string to cut.}
        }
        example {ztcl::text bounds "ab́c"} {0 1 3 4}
        example {ztcl::text bounds ""} 0
        error {ztcl::text bounds} {wrong # args: should be "ztcl::text bounds ?-unit grapheme|word|sentence? string"} {TCL WRONGARGS}
        error {ztcl::text bounds -bogus a} {wrong # args: should be "ztcl::text bounds ?-unit grapheme|word|sentence? string"} {TCL WRONGARGS}
        option -unit {
            value UNIT
            type {grapheme, word, or sentence}
            default grapheme
            values {grapheme word sentence}
            summary {Gives the unit to cut at.}
            description {`grapheme` gives the boundaries of `graphemes`, `word` of `words -all`, and `sentence` of `sentences`. The value has no short form.}
            example {ztcl::text bounds -unit word "hi there"} {0 2 3 8}
            example {ztcl::text bounds -unit sentence "A b. C d."} {0 5 9}
            error {ztcl::text bounds -unit line a} {bad unit "line": must be grapheme, word, or sentence} {TCL LOOKUP INDEX value}
            error {ztcl::text bounds -unit w a} {bad unit "w": must be grapheme, word, or sentence} {TCL LOOKUP INDEX value}
        }
    }
}
