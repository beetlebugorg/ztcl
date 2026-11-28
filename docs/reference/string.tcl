# Converted by tools/refdoc.tcl convert from strings.txt.

command string {
    area strings
    since TODO
    synopsis {string subcommand ?arg ...?}
    summary {The commands for text.}
    description {The commands for text. An index is a character index from 0, and `end` or `end-N` counts from the last character.}
    example {string length "buy milk"} 8
    example {string range "buy milk" 4 end} milk
    example {string length -grapheme "\U1F1FA\U1F1F8 e\u0301"} 3
    example {string equal [string reverse -grapheme "ae\u0301"] "e\u0301a"} 1
    example {string map {a 1 b 2} abcab} 12c12
    example {string is integer -strict ""} 0
    example {string first k "buy milk"} 7
    error {string nope x} {unknown or ambiguous subcommand "nope": must be cat, compare, equal, first, index, insert, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart} NONE -tcl 9.1
    subcommand length {
        synopsis {string length STRING}
        synopsis {string length -grapheme STRING}
        summary {The count of characters.}
        description {
            The count of characters.

            `string length -grapheme STRING`: The count of grapheme clusters. It needs the module ztcl::text in the build, and no `package require`.
        }
    }
    subcommand bytelength {
        synopsis {string bytelength STRING}
        summary {The count of bytes of the UTF-8 form.}
        description {The count of bytes of the UTF-8 form.}
        tcl 8.6
    }
    subcommand insert {
        synopsis {string insert STRING INDEX TEXT}
        summary {STRING with TEXT before the character at INDEX.}
        description {STRING with TEXT before the character at INDEX. `end` puts TEXT after the last character.}
        tcl 9.1
    }
    subcommand index {
        synopsis {string index STRING INDEX}
        synopsis {string index -grapheme STRING INDEX}
        summary {The character at INDEX, or an empty string past the end.}
        description {
            The character at INDEX, or an empty string past the end.

            `string index -grapheme STRING INDEX`: The grapheme cluster at INDEX, with INDEX in clusters.
        }
    }
    subcommand range {
        synopsis {string range STRING FIRST LAST}
        synopsis {string range -grapheme STRING FIRST LAST}
        summary {The characters from FIRST to LAST.}
        description {
            The characters from FIRST to LAST.

            `string range -grapheme STRING FIRST LAST`: The grapheme clusters from FIRST to LAST.
        }
    }
    subcommand first {
        synopsis {string first NEEDLE HAYSTACK ?START?}
        summary {The index of the first NEEDLE from START, or -1.}
        description {The index of the first NEEDLE from START, or -1.}
    }
    subcommand last {
        synopsis {string last NEEDLE HAYSTACK ?LAST?}
        summary {The index of the last NEEDLE at or before LAST, or -1.}
        description {The index of the last NEEDLE at or before LAST, or -1.}
    }
    subcommand compare {
        synopsis {string compare ?-nocase? ?-length N? A B}
        summary {-1, 0, or 1 in the order of the characters.}
        description {-1, 0, or 1 in the order of the characters.}
    }
    subcommand equal {
        synopsis {string equal ?-nocase? ?-length N? A B}
        summary {1 when the strings are the same, else 0.}
        description {1 when the strings are the same, else 0.}
    }
    subcommand match {
        synopsis {string match ?-nocase? PATTERN STRING}
        summary {1 when the glob PATTERN matches all of STRING.}
        description {1 when the glob PATTERN matches all of STRING. `*` is any text, `?` is one character, and `[a-z]` is a set.}
    }
    subcommand map {
        synopsis {string map ?-nocase? MAPPING STRING}
        summary {Replaces each key of the key and value list MAPPING with its value.}
        description {Replaces each key of the key and value list MAPPING with its value. It reads STRING once, from left to right, and at each place it tries the keys in their order.}
    }
    subcommand repeat {
        synopsis {string repeat STRING COUNT}
        summary {STRING COUNT times.}
        description {STRING COUNT times.}
    }
    subcommand replace {
        synopsis {string replace STRING FIRST LAST ?NEW?}
        summary {STRING with the characters from FIRST to LAST replaced by NEW.}
        description {STRING with the characters from FIRST to LAST replaced by NEW.}
    }
    subcommand reverse {
        synopsis {string reverse STRING}
        synopsis {string reverse -grapheme STRING}
        summary {The characters in the reverse order.}
        description {
            The characters in the reverse order.

            `string reverse -grapheme STRING`: The grapheme clusters in the reverse order, each with its characters in order.
        }
    }
    subcommand tolower {
        synopsis {string tolower STRING ?FIRST? ?LAST?}
        summary Lowercase.
        description {Lowercase.}
    }
    subcommand toupper {
        synopsis {string toupper STRING ?FIRST? ?LAST?}
        summary Uppercase.
        description {Uppercase.}
    }
    subcommand totitle {
        synopsis {string totitle STRING ?FIRST? ?LAST?}
        summary {The first character uppercase and the rest lowercase.}
        description {The first character uppercase and the rest lowercase.}
    }
    subcommand trim {
        synopsis {string trim STRING ?CHARS?}
        summary {STRING with the CHARS (white space by default) removed at both ends.}
        description {STRING with the CHARS (white space by default) removed at both ends.}
    }
    subcommand trimleft {
        synopsis {string trimleft STRING ?CHARS?}
        summary {The same at the start only.}
        description {The same at the start only.}
    }
    subcommand trimright {
        synopsis {string trimright STRING ?CHARS?}
        summary {The same at the end only.}
        description {The same at the end only.}
    }
    subcommand is {
        synopsis {string is CLASS ?-strict? ?-failindex VAR? STRING}
        summary {1 when each character is of CLASS: `alnum`, `alpha`, `ascii`, `boolean`, `digit`, `double`, `integer`, `wideinteger`, `list`, `lower`, `upper`, `space`, `xdigit`, and others.}
        description {1 when each character is of CLASS: `alnum`, `alpha`, `ascii`, `boolean`, `digit`, `double`, `integer`, `wideinteger`, `list`, `lower`, `upper`, `space`, `xdigit`, and others. Without `-strict` an empty string gives 1. The class `dict` is in}
        tcl 9.1
    }
    subcommand cat {
        synopsis {string cat ?STRING ...?}
        summary {The strings joined with no separator.}
        description {The strings joined with no separator.}
    }
    subcommand wordstart {
        synopsis {string wordstart STRING INDEX}
        summary {The index of the first character of the word at INDEX.}
        description {The index of the first character of the word at INDEX.}
    }
    subcommand wordend {
        synopsis {string wordend STRING INDEX}
        summary {The index after the last character of the word at INDEX.}
        description {The index after the last character of the word at INDEX.}
    }
}
