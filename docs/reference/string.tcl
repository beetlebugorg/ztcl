# The command reference: string. The format is in
# docs/dev/reference-format.md.

command string {
    area strings
    since 1.0.0-beta.1
    synopsis {string SUBCOMMAND ?ARG ...?}
    summary {The commands for text: length, search, compare, change, and test.}
    description {
        The commands for text. The first argument names the subcommand, and a unique prefix of its name is enough: `string len abc` is `string length abc`.

        A string is a sequence of characters, and each character is one Unicode code point. An index counts characters from 0. Each argument that is an index can be an integer, `end`, or `end-N` and `end+N` for a count from the last character. An index can also be `M+N` or `M-N` with two integers, such as `1+1`. An index before the first character or after the last one is valid: each subcommand names what it does with it.

        A string can have any characters, also the NUL character. An empty string is valid for each argument that is a string.

        A unique prefix of an option of `compare`, `equal`, `match`, `map`, and `is` is the option: `-n` is `-nocase`.

        The option `-grapheme` of `length`, `index`, `range`, and `reverse` counts grapheme clusters in place of characters. A grapheme cluster is what a reader sees as one character, such as `e` with a combining accent, or a flag of two regional indicators. It needs the module ztcl::text in the build, with no `package require`.
    }
    returns {The result of the subcommand.}
    see {append format scan split join regexp regsub tcl::prefix encoding}
    release {Tcl 9.1 adds `string insert` and the class `dict` of `string is`, and has no `string bytelength`.}
    release {In Tcl 9.1 an integer of `string is integer` can have `_` between its digits, such as `1_000`.}
    example {string length "buy milk"} 8
    example {string range "buy milk" 4 end} milk
    example {string length -grapheme "\U1F1FA\U1F1F8 é"} 3 -note {A flag of two regional indicators, a space, and e with a combining accent: three grapheme clusters.}
    example {string equal [string reverse -grapheme "aé"] "éa"} 1
    example {string map {a 1 b 2} abcab} 12c12
    example {string is integer -strict ""} 0
    example {string first k "buy milk"} 7
    example {string len abc} 3 -note {A unique prefix of a subcommand is the subcommand.}
    error {string nope x} {unknown or ambiguous subcommand "nope": must be cat, compare, equal, first, index, insert, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart} {TCL LOOKUP SUBCOMMAND nope} -tcl 9.1
    error {string nope x} {unknown or ambiguous subcommand "nope": must be bytelength, cat, compare, equal, first, index, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart} {TCL LOOKUP SUBCOMMAND nope} -tcl 8.6
    error {string t abc} {unknown or ambiguous subcommand "t": must be cat, compare, equal, first, index, insert, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart} {TCL LOOKUP SUBCOMMAND t} -tcl 9.1 -note {The prefix t matches more than one subcommand.}

    subcommand length {
        synopsis {string length STRING}
        synopsis {string length -grapheme STRING}
        summary {Gives the count of characters of a string.}
        description {
            Gives the count of characters (code points) of STRING. An empty string has length 0. A character outside the Basic Multilingual Plane, such as an emoji, counts as one character.

            With `-grapheme` it gives the count of grapheme clusters. With one argument, `string length -grapheme` is the length of the text `-grapheme`, so the option needs a string after it.
        }
        returns {A non-negative integer.}
        see {{string bytelength} {string index} llength}
        argument STRING {
            type string
            summary {The text to count.}
        }
        example {string length "buy milk"} 8
        example {string length ""} 0
        example {string length -grapheme} 9 -note {With one argument, -grapheme is the string.}
        error {string length a b} {wrong # args: should be "string length string"} {TCL WRONGARGS}
        option -grapheme {
            type flag
            summary {Counts grapheme clusters in place of characters.}
            description {
                Counts the grapheme clusters of STRING with the rules of Unicode text segmentation. A base letter and its combining marks are one cluster, a flag of two regional indicators is one cluster, and an emoji sequence joined with U+200D is one cluster. An empty string has 0 clusters.

                The option has no prefix form: `-g` or `-graph` is an error of the count of arguments.
            }
            example {string length -grapheme "é"} 1
            example {string length "\U1F468‍\U1F469‍\U1F467"} 5 -note {A family emoji: three code points joined by two U+200D.}
            example {string length -grapheme "\U1F468‍\U1F469‍\U1F467"} 1
            error {string length -g abc} {wrong # args: should be "string length string"} {TCL WRONGARGS}
        }
    }

    subcommand bytelength {
        synopsis {string bytelength STRING}
        summary {Gives the count of bytes of the UTF-8 form of a string.}
        description {
            Gives the count of bytes of STRING in UTF-8. A character below U+0080 is one byte, and each other character is two to four bytes.

            The subcommand is in Tcl 8.6 only. In Tcl 9.1 use `string length [encoding convertto utf-8 STRING]`.
        }
        returns {A non-negative integer.}
        tcl 8.6
        see {{string length} encoding}
        argument STRING {
            type string
            summary {The text to measure.}
        }
        example {string bytelength "café"} 5
        example {string bytelength ""} 0
        error {string bytelength} {wrong # args: should be "string bytelength string"} {TCL WRONGARGS}
    }

    subcommand insert {
        synopsis {string insert STRING INDEX TEXT}
        summary {Gives a string with text put before the character at an index.}
        description {
            Gives STRING with TEXT before the character at INDEX. The variable of STRING does not change.

            An INDEX at or below 0 puts TEXT at the start. `end` puts TEXT after the last character, and so does each index past the end. An empty TEXT gives STRING.

            The subcommand is in Tcl 9.1 only.
        }
        returns {The new string.}
        tcl 9.1
        see {{string replace} {string range} linsert}
        argument STRING {
            type string
            summary {The text to change.}
        }
        argument INDEX {
            type index
            summary {The place of TEXT: an integer, `end`, or `end-N`.}
        }
        argument TEXT {
            type string
            summary {The text to put in.}
        }
        example {string insert abc 1 X} aXbc
        example {string insert abc end X} abcX
        example {string insert abc -5 X} Xabc
        example {string insert abc 10 X} abcX
        error {string insert abc x X} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
        error {string insert abc 1} {wrong # args: should be "string insert string index insertString"} {TCL WRONGARGS}
    }

    subcommand index {
        synopsis {string index STRING INDEX}
        synopsis {string index -grapheme STRING INDEX}
        summary {Gives the character at an index of a string.}
        description {
            Gives the character of STRING at INDEX. An index before the first character or after the last one gives an empty string, and so does each index of an empty string.

            With `-grapheme`, INDEX counts grapheme clusters, and the result is the whole cluster at that place.
        }
        returns {One character, one grapheme cluster with `-grapheme`, or an empty string.}
        see {{string range} lindex}
        argument STRING {
            type string
            summary {The text.}
        }
        argument INDEX {
            type index
            summary {An integer from 0, `end`, `end-N`, or `M+N`.}
        }
        example {string index abc 1} b
        example {string index abc end-1} b
        example {string index abc 1+1} c
        example {string index abc 5} {}
        example {string index abc -1} {}
        error {string index abc foo} {bad index "foo": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
        error {string index abc} {wrong # args: should be "string index string charIndex"} {TCL WRONGARGS}
        option -grapheme {
            type flag
            summary {Counts INDEX in grapheme clusters, and gives a whole cluster.}
            description {
                INDEX counts grapheme clusters, and the result is the cluster at that place with each of its code points. An index past the last cluster gives an empty string.

                With two arguments, `-grapheme` is the string and the other argument is the index.
            }
            example {string index -grapheme "aéb" 1} "e\u0301"
            example {string index -grapheme "aéb" end} b
            error {string index -grapheme abc} {bad index "abc": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX} -note {With two arguments, -grapheme is the string and abc is the index.}
        }
    }

    subcommand range {
        synopsis {string range STRING FIRST LAST}
        synopsis {string range -grapheme STRING FIRST LAST}
        summary {Gives the characters of a string from one index to another.}
        description {
            Gives the characters of STRING from FIRST to LAST, both included. A FIRST below 0 counts as 0, and a LAST past the end counts as the last character. When FIRST is after LAST, after the clamp, the result is an empty string.

            With `-grapheme`, FIRST and LAST count grapheme clusters.
        }
        returns {A string, empty when the range has no character.}
        see {{string index} {string replace} lrange}
        argument STRING {
            type string
            summary {The text.}
        }
        argument FIRST {
            type index
            summary {The index of the first character of the result.}
        }
        argument LAST {
            type index
            summary {The index of the last character of the result.}
        }
        example {string range abcdef 1 3} bcd
        example {string range abcdef end-2 end} def
        example {string range abcdef -5 2} abc
        example {string range abcdef 3 1} {}
        error {string range abc 1} {wrong # args: should be "string range string first last"} {TCL WRONGARGS}
        error {string range abc x 1} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
        option -grapheme {
            type flag
            summary {Counts FIRST and LAST in grapheme clusters.}
            description {
                FIRST and LAST count grapheme clusters, so the result never splits a letter from its combining marks or a flag in two. The rules of the clamp are the same as for characters.
            }
            example {string range -grapheme "aéio" 1 2} "e\u0301i"
            example {string range "aéio" 1 2} "e\u0301" -note {With no option, the range is two code points: e and the accent.}
            error {string range -grapheme abc 0 x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
        }
    }

    subcommand first {
        synopsis {string first NEEDLE HAYSTACK ?START?}
        summary {Gives the index of the first match of a substring.}
        description {
            Searches HAYSTACK for the text NEEDLE, from START to the end, and gives the index of the first character of the first match. The match is exact: the case of letters counts, and NEEDLE has no pattern characters.

            START is 0 by default. A START below 0 counts as 0, and a START past the end gives -1. An empty NEEDLE gives -1.
        }
        returns {The index of the match, or -1 when HAYSTACK has no match.}
        see {{string last} {string match} lsearch regexp}
        argument NEEDLE {
            type string
            summary {The text to find.}
        }
        argument HAYSTACK {
            type string
            summary {The text to search.}
        }
        argument START {
            type index
            default 0
            summary {The index where the search starts.}
            optional
        }
        example {string first k "buy milk"} 7
        example {string first ab xxabab 3} 4
        example {string first ab xxabab end-1} 4
        example {string first k "buy milk" 8} -1
        example {string first "" abc} -1
        error {string first a} {wrong # args: should be "string first needleString haystackString ?startIndex?"} {TCL WRONGARGS}
        error {string first k kk x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
    }

    subcommand last {
        synopsis {string last NEEDLE HAYSTACK ?LAST?}
        summary {Gives the index of the last match of a substring.}
        description {
            Searches HAYSTACK for the text NEEDLE, from LAST back to the start, and gives the index of the first character of the last match that starts at or before LAST. The match is exact, as for `string first`.

            LAST is `end` by default. A LAST past the end counts as `end`, and a LAST below 0 gives -1. An empty NEEDLE gives -1.
        }
        returns {The index of the match, or -1 when HAYSTACK has no match.}
        release {In Tcl 9.1 the message of a wrong count of arguments names the third argument `?lastIndex?`, and in Tcl 8.6 `?startIndex?`.}
        see {{string first} lsearch}
        argument NEEDLE {
            type string
            summary {The text to find.}
        }
        argument HAYSTACK {
            type string
            summary {The text to search.}
        }
        argument LAST {
            type index
            default end
            summary {The last index where a match can start.}
            optional
        }
        example {string last ab xxabab} 4
        example {string last ab xxabab 3} 2
        example {string last ab xxabab 1} -1
        example {string last ab xxabab 100} 4
        error {string last a} {wrong # args: should be "string last needleString haystackString ?startIndex?"} {TCL WRONGARGS} -tcl 8.6
        error {string last a} {wrong # args: should be "string last needleString haystackString ?lastIndex?"} {TCL WRONGARGS} -tcl 9.1
        error {string last a abc x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
    }

    subcommand compare {
        synopsis {string compare ?-nocase? ?-length N? A B}
        summary {Compares two strings character by character.}
        description {
            Compares A and B one character at a time, by the code point of each character. The first pair that differs gives the order. When one string is a prefix of the other, the shorter one is first. An empty string is before each other string.

            The options come before A and B, each at most once, in any order. With exactly two arguments, the words are A and B also when they start with `-`: `string compare -nocase a` compares the text `-nocase` with `a`.
        }
        returns {-1 when A is before B, 0 when they are equal, and 1 when A is after B.}
        see {{string equal} lsort}
        argument A {
            type string
            summary {The first string.}
        }
        argument B {
            type string
            summary {The second string.}
        }
        example {string compare abc abd} -1
        example {string compare abd abc} 1
        example {string compare a ab} -1
        example {string compare "" a} -1
        error {string compare a} {wrong # args: should be "string compare ?-nocase? ?-length int? string1 string2"} {TCL WRONGARGS}
        option -nocase {
            type flag
            summary {Compares the letters as lowercase.}
            description {
                Compares each pair of characters after a change to lowercase, so `A` and `a` are equal. It works for each letter with a case in Unicode, such as `É` and `é`. With `-length`, the case rule applies to the first N characters.
            }
            example {string compare -nocase ABC abc} 0
            example {string compare B a} -1 -note {B (U+0042) is before a (U+0061).}
            example {string compare -nocase B a} 1
            example {string compare -n A a} 0 -note {A unique prefix of an option is the option.}
            error {string compare -bogus a b} {bad option "-bogus": must be -nocase or -length} {TCL LOOKUP INDEX option -bogus}
        }
        option -length {
            value N
            type integer
            summary {Compares only the first N characters of each string.}
            description {
                Compares at most the first N characters of A and of B. A string shorter than N compares as a whole. N of 0 gives 0, and a negative N compares the whole strings.
            }
            example {string compare -length 2 abc abd} 0
            example {string compare -length -1 abc abd} -1
            example {string compare -nocase -length 2 ABx abY} 0
            error {string compare -length x abc abd} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
    }

    subcommand equal {
        synopsis {string equal ?-nocase? ?-length N? A B}
        summary {Tests whether two strings are the same text.}
        description {
            Gives 1 when A and B have the same characters in the same order, else 0. The test is on the text: `1` and `1.0` are different strings, while `expr {1 == 1.0}` is true. Two empty strings are equal.

            The options follow the rules of `string compare`.
        }
        returns {1 or 0.}
        see {{string compare} expr}
        argument A {
            type string
            summary {The first string.}
        }
        argument B {
            type string
            summary {The second string.}
        }
        example {string equal abc abc} 1
        example {string equal 1 1.0} 0
        example {string equal "" ""} 1
        error {string equal a} {wrong # args: should be "string equal ?-nocase? ?-length int? string1 string2"} {TCL WRONGARGS}
        option -nocase {
            type flag
            summary {Treats each uppercase letter as its lowercase letter.}
            description {
                Compares the strings after a change of each letter to lowercase, also for letters outside ASCII, such as `É` and `é`.
            }
            example {string equal -nocase ABC abc} 1
            example {string equal -nocase "É" "é"} 1
            error {string equal -nocase a b c} {bad option "a": must be -nocase or -length} {TCL LOOKUP INDEX option a}
        }
        option -length {
            value N
            type integer
            summary {Tests only the first N characters of each string.}
            description {
                Tests at most the first N characters of A and of B. N of 0 gives 1, and a negative N tests the whole strings.
            }
            example {string equal -length 2 abc abd} 1
            example {string equal -length 0 a b} 1
            example {string equal -length -1 abc abd} 0
            error {string equal -length x a b} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
    }

    subcommand match {
        synopsis {string match ?-nocase? PATTERN STRING}
        summary {Tests whether a glob pattern matches the whole of a string.}
        description {
            Gives 1 when PATTERN matches all of STRING, else 0. These characters of PATTERN have a meaning, and each other character matches itself:

            - `*` matches any text, also an empty one.
            - `?` matches one character.
            - `[chars]` matches one character of the set. `a-z` in a set is a range. A set with no `]` runs to the end of the pattern. A set has no negation: `^` and `!` are characters of the set.
            - `\x` matches the character x, so `\*` matches a star.

            An empty PATTERN matches only an empty STRING, and `*` matches each string.
        }
        returns {1 or 0.}
        see {glob lsearch switch regexp {string first}}
        argument PATTERN {
            type {glob pattern}
            summary {The pattern.}
        }
        argument STRING {
            type string
            summary {The text to test.}
        }
        example {string match a* abc} 1
        example {string match {[a-c]?} bx} 1
        example {string match {a\*} a*} 1
        example {string match {[!a]} b} 0
        example {string match ? ""} 0
        error {string match a} {wrong # args: should be "string match ?-nocase? pattern string"} {TCL WRONGARGS}
        option -nocase {
            type flag
            summary {Matches letters with no regard to case.}
            description {
                Matches each letter of PATTERN and of STRING as lowercase, also in a set: `[A-C]` matches `b`. With two arguments in place of three, `-nocase` is the pattern.
            }
            example {string match -nocase A* abc} 1
            example {string match -nocase {[A-C]} b} 1
            example {string match -nocase a} 0 -note {With two arguments, -nocase is the pattern and a is the string.}
            error {string match -bogus a a} {bad option "-bogus": must be -nocase} {TCL LOOKUP INDEX option -bogus}
        }
    }

    subcommand map {
        synopsis {string map ?-nocase? MAPPING STRING}
        summary {Replaces each key of a list of keys and values with its value.}
        description {
            MAPPING is a list of keys and values: `{key1 value1 key2 value2 ...}`. The command reads STRING once, from left to right. At each place it tries the keys in the order of MAPPING, and the first key that starts there goes out as its value. The value is not read again, so `string map {a b b a} ab` swaps the two letters. When no key starts at a place, its character goes out as it is.

            The order of MAPPING matters when one key is a prefix of another: put the longer key first. A key that is an empty string never matches. An empty MAPPING or an empty STRING gives STRING.
        }
        returns {The new string.}
        see {regsub {string replace} dict}
        argument MAPPING {
            type list
            summary {A list with an even count of elements: each key followed by its value.}
        }
        argument STRING {
            type string
            summary {The text to change.}
        }
        example {string map {a 1 b 2} abcab} 12c12
        example {string map {abc 1 ab 2 a 3} abcaba} 123
        example {string map {ab X a Y} aab} YX
        example {string map {a b b a} ab} ba
        example {string map {a {}} banana} bnn
        error {string map {a} abc} {char map list unbalanced} {TCL OPERATION MAP UNBALANCED}
        error {string map a} {wrong # args: should be "string map ?-nocase? charMap string"} {TCL WRONGARGS}
        error {string map {a 1} abc extra} {bad option "a 1": must be -nocase} {TCL LOOKUP INDEX option {a 1}} -note {With three arguments, the first one is an option.}
        option -nocase {
            type flag
            summary {Matches the keys with no regard to the case of letters.}
            description {
                Matches a key at a place when the two are equal after a change of each letter to lowercase, also for letters outside ASCII, as `string equal -nocase` compares. The value goes out as it is in MAPPING.
            }
            example {string map -nocase {ab X} "AB aB"} {X X}
            example {string map -nocase {é E} "É"} E
            example {string map -nocase {Σ x} "σς"} xς -note {The lowercase of `Σ` is `σ`. The final form `ς` is another letter.}
            error {string map -nocase {a} abc} {char map list unbalanced} {TCL OPERATION MAP UNBALANCED}
        }
    }

    subcommand repeat {
        synopsis {string repeat STRING COUNT}
        summary {Gives a string repeated a number of times.}
        description {
            Gives STRING COUNT times, with no separator. A COUNT of 0 or below gives an empty string, and so does an empty STRING. The result counts toward the memory limit of the interpreter.
        }
        returns {The new string.}
        see {lrepeat {string cat}}
        argument STRING {
            type string
            summary {The text to repeat.}
        }
        argument COUNT {
            type integer
            summary {The count of copies.}
        }
        example {string repeat ab 3} ababab
        example {string repeat ab 0} {}
        example {string repeat ab -1} {}
        error {string repeat ab x} {expected integer but got "x"} {TCL VALUE NUMBER}
        error {string repeat a} {wrong # args: should be "string repeat string count"} {TCL WRONGARGS}
    }

    subcommand replace {
        synopsis {string replace STRING FIRST LAST ?NEW?}
        summary {Gives a string with a range of characters replaced by other text.}
        description {
            Gives STRING with the characters from FIRST to LAST, both included, replaced by NEW. With no NEW the range goes away. The variable of STRING does not change.

            A FIRST below 0 counts as 0, and a LAST past the end counts as the last character. When the range has no character of STRING, such as with FIRST after LAST or FIRST past the end, the result is STRING with no change: NEW does not go in.
        }
        returns {The new string.}
        see {{string insert} {string range} {string map} lreplace}
        argument STRING {
            type string
            summary {The text to change.}
        }
        argument FIRST {
            type index
            summary {The index of the first character to replace.}
        }
        argument LAST {
            type index
            summary {The index of the last character to replace.}
        }
        argument NEW {
            type string
            default {""}
            summary {The text that goes in place of the range.}
            optional
        }
        example {string replace abcdef 1 3 X} aXef
        example {string replace abcdef 1 3} aef
        example {string replace abcdef end end Z} abcdeZ
        example {string replace abcdef 4 10 X} abcdX
        example {string replace abcdef 3 1 X} abcdef
        error {string replace a} {wrong # args: should be "string replace string first last ?string?"} {TCL WRONGARGS}
        error {string replace abc x 1 Z} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
    }

    subcommand reverse {
        synopsis {string reverse STRING}
        synopsis {string reverse -grapheme STRING}
        summary {Gives the characters of a string in the reverse order.}
        description {
            Gives the characters of STRING from the last to the first. A combining mark moves to the other side of its letter, so text with accents can change its look. `-grapheme` keeps each grapheme cluster whole.

            With one argument, `string reverse -grapheme` reverses the text `-grapheme`.
        }
        returns {The new string.}
        see {lreverse}
        argument STRING {
            type string
            summary {The text to reverse.}
        }
        example {string reverse abc} cba
        example {string reverse ""} {}
        example {string reverse -grapheme} emehparg-
        error {string reverse} {wrong # args: should be "string reverse string"} {TCL WRONGARGS}
        option -grapheme {
            type flag
            summary {Reverses the order of the grapheme clusters, each with its characters in order.}
            description {
                Reverses the order of the grapheme clusters of STRING. The code points of each cluster keep their order, so a letter keeps its accent and a flag stays the same flag.
            }
            example {string equal [string reverse -grapheme "aé"] "éa"} 1
            example {string equal [string reverse "aé"] "́ea"} 1 -note {With no option, the accent moves before its letter.}
            example {string reverse -grapheme "\U1F1FA\U1F1F8\U1F1EC\U1F1E7"} "\U1F1EC\U1F1E7\U1F1FA\U1F1F8"
            error {string reverse -grapheme a b} {wrong # args: should be "string reverse string"} {TCL WRONGARGS}
        }
    }

    subcommand tolower {
        synopsis {string tolower STRING ?FIRST? ?LAST?}
        summary {Gives a string with its letters in lowercase.}
        description {
            Gives STRING with each uppercase letter changed to lowercase, with the case rules of Unicode for one character. Each other character stays.

            With FIRST, only the characters from FIRST to LAST change. LAST is FIRST by default, so `string tolower ABC 1` changes one character. The range has the clamp of `string range`, and a range with no character gives STRING.
        }
        returns {The new string.}
        see {{string toupper} {string totitle}}
        argument STRING {
            type string
            summary {The text to change.}
        }
        argument FIRST {
            type index
            default 0
            summary {The index of the first character to change.}
            optional
        }
        argument LAST {
            type index
            default {FIRST, or end with no FIRST}
            summary {The index of the last character to change.}
            optional
        }
        example {string tolower ABC} abc
        example {string tolower ABC 1} AbC
        example {string tolower ABCDEF 1 3} AbcdEF
        example {string tolower "ÀÉÎ"} {àéî}
        error {string tolower} {wrong # args: should be "string tolower string ?first? ?last?"} {TCL WRONGARGS}
        error {string tolower ABC 1 x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
    }

    subcommand toupper {
        synopsis {string toupper STRING ?FIRST? ?LAST?}
        summary {Gives a string with its letters in uppercase.}
        description {
            Gives STRING with each lowercase letter changed to uppercase, one character at a time: a letter that becomes two letters in a full case change, such as `ß`, stays as it is. FIRST and LAST follow the rules of `string tolower`.
        }
        returns {The new string.}
        see {{string tolower} {string totitle}}
        argument STRING {
            type string
            summary {The text to change.}
        }
        argument FIRST {
            type index
            default 0
            summary {The index of the first character to change.}
            optional
        }
        argument LAST {
            type index
            default {FIRST, or end with no FIRST}
            summary {The index of the last character to change.}
            optional
        }
        example {string toupper abc} ABC
        example {string toupper abc 0 0} Abc
        example {string toupper straße} {STRAßE}
        example {string toupper abc 2 1} abc
        error {string toupper} {wrong # args: should be "string toupper string ?first? ?last?"} {TCL WRONGARGS}
    }

    subcommand totitle {
        synopsis {string totitle STRING ?FIRST? ?LAST?}
        summary {Gives a string with its first character in title case and the rest in lowercase.}
        description {
            Gives STRING with its first character in title case and each other character in lowercase. Title case is uppercase for most letters, and the title form for a letter such as `ǆ`. The command changes only the first character of the whole string, and the first letter of each other word goes to lowercase.

            With FIRST and LAST it changes only that range: the character at FIRST goes to title case and the rest of the range to lowercase.
        }
        returns {The new string.}
        see {{string toupper} {string tolower}}
        argument STRING {
            type string
            summary {The text to change.}
        }
        argument FIRST {
            type index
            default 0
            summary {The index of the first character to change.}
            optional
        }
        argument LAST {
            type index
            default {FIRST, or end with no FIRST}
            summary {The index of the last character to change.}
            optional
        }
        example {string totitle "hELLO wORLD"} {Hello world}
        example {string totitle "hello world" 6 end} {hello World}
        example {string totitle ǆemal} {ǅemal}
        error {string totitle abc x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
        error {string totitle} {wrong # args: should be "string totitle string ?first? ?last?"} {TCL WRONGARGS}
    }

    subcommand trim {
        synopsis {string trim STRING ?CHARS?}
        summary {Gives a string with given characters removed at both ends.}
        description {
            Removes each character of the set CHARS from the start and from the end of STRING, until a character outside the set. The characters inside the string stay. CHARS is a set: its order and its repeats do not matter.

            With no CHARS the set is white space: the space, the tab, the line feed, the carriage return, the vertical tab, the form feed, the NUL character, and the Unicode spaces such as U+00A0 and U+2003. An empty CHARS removes no character.
        }
        returns {The new string.}
        see {{string trimleft} {string trimright}}
        argument STRING {
            type string
            summary {The text to trim.}
        }
        argument CHARS {
            type string
            default {white space}
            summary {The set of characters to remove.}
            optional
        }
        example {string trim "  a b  "} {a b}
        example {string trim abcXcba abc} X
        example {string trim " x "} x
        example {string trim abc ""} abc
        error {string trim abc x y} {wrong # args: should be "string trim string ?chars?"} {TCL WRONGARGS}
    }

    subcommand trimleft {
        synopsis {string trimleft STRING ?CHARS?}
        summary {Gives a string with given characters removed at the start.}
        description {
            Removes each character of the set CHARS from the start of STRING only. CHARS follows the rules of `string trim`.
        }
        returns {The new string.}
        see {{string trim} {string trimright}}
        argument STRING {
            type string
            summary {The text to trim.}
        }
        argument CHARS {
            type string
            default {white space}
            summary {The set of characters to remove.}
            optional
        }
        example {string trimleft "  a  "} {a  }
        example {string trimleft 0012 0} 12
        error {string trimleft} {wrong # args: should be "string trimleft string ?chars?"} {TCL WRONGARGS}
    }

    subcommand trimright {
        synopsis {string trimright STRING ?CHARS?}
        summary {Gives a string with given characters removed at the end.}
        description {
            Removes each character of the set CHARS from the end of STRING only. CHARS follows the rules of `string trim`.
        }
        returns {The new string.}
        see {{string trim} {string trimleft}}
        argument STRING {
            type string
            summary {The text to trim.}
        }
        argument CHARS {
            type string
            default {white space}
            summary {The set of characters to remove.}
            optional
        }
        example {string trimright "  a  "} {  a}
        example {string trimright 1.500 0} 1.5
        error {string trimright} {wrong # args: should be "string trimright string ?chars?"} {TCL WRONGARGS}
    }

    subcommand is {
        synopsis {string is CLASS ?-strict? ?-failindex VAR? STRING}
        summary {Tests whether a string is of a class, such as integer or alpha.}
        description {
            Gives 1 when STRING is of CLASS, else 0. For a class of characters, such as `alpha` or `digit`, each character of STRING must be in the class. For a class of values, such as `integer` or `list`, the whole STRING must be a valid value of the type.

            An empty STRING gives 1 for each class with no `-strict`. A unique prefix of a class name is the class: `string is int 12` tests `integer`.

            The options come after CLASS and before STRING. With no word after the options, the last word is STRING: `string is integer -strict` tests the text `-strict`.
        }
        returns {1 or 0.}
        see {{string match} expr regexp}
        argument CLASS {
            type {class name}
            summary {The class to test.}
            choice alnum {Each character is a Unicode letter or digit.}
            choice alpha {Each character is a Unicode letter.}
            choice ascii {Each character is below U+0080.}
            choice boolean {A boolean of Tcl: `0`, `1`, `true`, `false`, `yes`, `no`, `on`, `off`, or a prefix of those words, in any case.}
            choice control {Each character is a control character.}
            choice dict {A valid dict: a list with an even count of elements.} -tcl 9.1
            choice digit {Each character is a Unicode decimal digit, also outside ASCII.}
            choice double {A valid floating-point number, also an integer, a hex integer, `nan`, `inf`, and a value too large for a double.}
            choice entier {A valid integer of any size.}
            choice false {A boolean that is false.}
            choice graph {Each character prints with ink: no space and no control character.}
            choice integer {A valid integer that fits in 64 bits, with optional white space around it.}
            choice list {A valid list.}
            choice lower {Each character is a lowercase letter.}
            choice print {Each character prints: a graph character or a space, and no control character.}
            choice punct {Each character is Unicode punctuation.}
            choice space {Each character is white space.}
            choice true {A boolean that is true.}
            choice upper {Each character is an uppercase letter.}
            choice wideinteger {A valid integer that fits in 64 bits.}
            choice wordchar {Each character is a letter, a digit, or a connector such as `_`.}
            choice xdigit {Each character is a hex digit: 0 to 9, a to f, or A to F.}
        }
        argument STRING {
            type string
            summary {The text to test.}
        }
        example {string is integer 12} 1
        example {string is digit 12a} 0
        example {string is double 1e5} 1
        example {string is boolean yes} 1
        example "string is list \"a \{b\"" 0
        example {string is dict {a 1}} 1 -tcl 9.1
        example {string is integer 1_000} 1 -tcl 9.1
        example {string is integer 1_000} 0 -tcl 8.6
        error {string is bogus x} {bad class "bogus": must be alnum, alpha, ascii, control, boolean, dict, digit, double, entier, false, graph, integer, list, lower, print, punct, space, true, upper, wideinteger, wordchar, or xdigit} {TCL LOOKUP INDEX class bogus} -tcl 9.1
        error {string is dict {a 1}} {bad class "dict": must be alnum, alpha, ascii, control, boolean, digit, double, entier, false, graph, integer, list, lower, print, punct, space, true, upper, wideinteger, wordchar, or xdigit} {TCL LOOKUP INDEX class dict} -tcl 8.6
        error {string is integer} {wrong # args: should be "string is class ?-strict? ?-failindex var? str"} {TCL WRONGARGS}
        option -strict {
            type flag
            summary {Makes an empty string give 0.}
            description {
                With `-strict` an empty STRING gives 0 for each class. A STRING that is not empty gives the same result with and without the option.
            }
            example {string is integer ""} 1
            example {string is integer -strict ""} 0
            example {string is alpha -strict abc} 1
            error {string is integer -strict -bogus ""} {bad option "-bogus": must be -strict or -failindex} {TCL LOOKUP INDEX option -bogus}
        }
        option -failindex {
            value VAR
            type {variable name}
            summary {Sets a variable to the index of the first character that fails the test.}
            description {
                When the result is 0, the command sets the variable VAR to the index of the first character where the test fails. For a class of values, such as `integer` or `list`, that is the place where the value stops being valid. An empty STRING with `-strict` sets VAR to 0. When the result is 1, VAR does not change, and a VAR with no value stays with no value.
            }
            example {
                string is alpha -failindex i ab1c
                set i
            } 2
            example {
                string is integer -failindex j 12x
                set j
            } 2
            example {
                unset -nocomplain k
                string is integer -failindex k 12
                info exists k
            } 0
            error {string is integer -failindex i} {wrong # args: should be "string is integer ?-strict? ?-failindex var? str"} {TCL WRONGARGS}
        }
    }

    subcommand cat {
        synopsis {string cat ?STRING ...?}
        summary {Joins strings with no separator.}
        description {
            Gives the strings one after the other, with no separator. With no argument it gives an empty string. Each argument is text: a list keeps its braces and spaces as they are, as `{a b}` and `{c d}` give `a bc d`.
        }
        returns {The joined string.}
        see {append concat join}
        noerrors {Each count of arguments is valid, also none, and each argument is valid text.}
        argument STRING {
            type string
            summary {A string to join.}
            optional
            repeats
        }
        example {string cat a b c} abc
        example {string cat {a b} {c d}} {a bc d}
        example {string cat} {}
    }

    subcommand wordstart {
        synopsis {string wordstart STRING INDEX}
        summary {Gives the index of the first character of the word at an index.}
        description {
            Gives the index of the first character of the word that has the character at INDEX. A word is a run of letters, digits, and connectors such as `_`. Each other character, such as a space or a period, is a word of its own one character long.

            An INDEX below 0 gives 0, and an INDEX past the end works as the last character.
        }
        returns {An index.}
        see {{string wordend} tcl_endOfWord}
        argument STRING {
            type string
            summary {The text.}
        }
        argument INDEX {
            type index
            summary {The index of a character in the word.}
        }
        example {string wordstart "hello world" 7} 6
        example {string wordstart foo_bar 5} 0
        example {string wordstart "hello world" 5} 5
        error {string wordstart "hello world" x} {bad index "x": must be integer?[+-]integer? or end?[+-]integer?} {TCL VALUE INDEX}
        error {string wordstart a} {wrong # args: should be "string wordstart string index"} {TCL WRONGARGS}
    }

    subcommand wordend {
        synopsis {string wordend STRING INDEX}
        summary {Gives the index after the last character of the word at an index.}
        description {
            Gives the index just after the last character of the word that has the character at INDEX. Words follow the rules of `string wordstart`.

            An INDEX below 0 or past the end gives the length of STRING, and an empty STRING gives 0.
        }
        returns {An index.}
        see {{string wordstart} tcl_endOfWord}
        argument STRING {
            type string
            summary {The text.}
        }
        argument INDEX {
            type index
            summary {The index of a character in the word.}
        }
        example {string wordend "hello world" 1} 5
        example {string wordend "hello world" 5} 6
        example {string wordend a.b 1} 2
        example {string wordend abc 10} 3
        error {string wordend a} {wrong # args: should be "string wordend string index"} {TCL WRONGARGS}
    }
}
