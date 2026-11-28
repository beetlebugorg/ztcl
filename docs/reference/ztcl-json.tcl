# The command reference: ztcl::json. The format is in
# docs/dev/reference-format.md.

command ztcl::json {
    area ztcl
    since 1.0.0-beta.1
    setup {package require ztcl::json}
    synopsis {ztcl::json SUBCOMMAND ?ARG ...?}
    summary {Parses, reads, checks, and writes JSON.}
    description {
        The commands for JSON (RFC 8259). `parse` gives the Tcl value of a JSON text: an object is a dict and an array is a list. `get` and `exists` read one value at a path with no full parse, `valid` checks a text, `encode` writes a Tcl value with a schema, the builders write one JSON value each, and `pretty` lays out a text.

        Load the module with `package require ztcl::json`. It needs no capability. Each subcommand is also the command `ztcl::json::NAME`, such as `ztcl::json::parse`.

        An error of the module has a code that starts with `ZT JSON`: `SYNTAX LINE COLUMN` for a syntax error, invalid UTF-8, or a control character in a string, `DEPTH` for nesting deeper than 512, `NUMBER` for a number of more than 1 MiB of text, `NULL` for a `null` with no `-null`, `PATH` for a path of `get` with no value, and `SCHEMA`, `TYPED`, or `VALUE` for an error of `encode`.

        A large text costs compute units as it is read: one for each 4,096 bytes and one for each value made, so the compute limit and the memory limit stop a parse of a large text early.
    }
    returns {The result of the subcommand.}
    page modules/json/
    names {ztcl::json::parse ztcl::json::valid ztcl::json::get ztcl::json::exists ztcl::json::encode ztcl::json::object ztcl::json::array ztcl::json::string ztcl::json::number ztcl::json::bool ztcl::json::null ztcl::json::raw ztcl::json::pretty}
    see {dict list {string map}}
    example {ztcl::json parse {{"a": [1, 2]}}} {a {1 2}}
    example {ztcl::json encode -schema {object {n int}} {n 5}} {{"n":5}}
    example {ztcl::json::get {{"a": {"b": [10, 20]}}} a b 1} 20
    error {ztcl::json bogus} {unknown or ambiguous subcommand "bogus": must be array, bool, encode, exists, get, null, number, object, parse, pretty, raw, string, or valid} {TCL LOOKUP SUBCOMMAND bogus}
    error {ztcl::json} {wrong # args: should be "ztcl::json subcommand ?arg ...?"} {TCL WRONGARGS}

    subcommand parse {
        synopsis {ztcl::json parse ?-null VALUE? ?-typed? ?--? TEXT}
        summary {Gives the Tcl value of a JSON text.}
        description {
            Reads TEXT, one JSON value with optional white space around it, and gives its Tcl value:

            - an object is a dict; a key that comes again keeps its first place and gets the last value, as `dict create` does;
            - an array is a list, and a string is a string;
            - a number that is an integer is an integer, also above 64 bits, and each other number is a double: `1e2` gives `100.0`;
            - `true` and `false` give the strings `true` and `false`;
            - `null` is an error with the code `ZT JSON NULL`, unless `-null` gives its value.

            A lone surrogate in a `\u` escape becomes U+FFFD. An empty TEXT and a text with more than one value are syntax errors.
        }
        returns {The Tcl value, or the typed tree with `-typed`.}
        see {{ztcl::json get} {ztcl::json valid}}
        argument TEXT {
            type {JSON text}
            summary {The text to read.}
        }
        example {ztcl::json parse {{"a": [1, 2]}}} {a {1 2}}
        example {ztcl::json parse {{"a": 1, "a": 2, "b": 3}}} {a 2 b 3}
        example {ztcl::json parse {[1, 2.0, 1e2, 99999999999999999999]}} {1 2.0 100.0 99999999999999999999}
        example {ztcl::json parse {[true, false]}} {true false}
        error {ztcl::json parse {[1,}} {json syntax error at line 1, column 4: value expected} {ZT JSON SYNTAX 1 4}
        error {ztcl::json parse {}} {json syntax error at line 1, column 1: no value} {ZT JSON SYNTAX 1 1}
        error {ztcl::json parse} {wrong # args: should be "ztcl::json parse ?-null value? ?-typed? ?--? text"} {TCL WRONGARGS}
        option -null {
            value VALUE
            type string
            summary {Gives the value of a JSON null.}
            description {Each `null` of TEXT becomes VALUE. With no `-null`, a `null` is an error.}
            example {ztcl::json parse -null NULL {[null, 1]}} {NULL 1}
            error {ztcl::json parse null} {json syntax error at line 1, column 1: null needs the option -null} {ZT JSON NULL}
        }
        option -typed {
            type flag
            summary {Gives a tree that keeps each JSON type.}
            description {Gives a tagged tree: `{object {KEY TREE ...}}`, `{array {TREE ...}}`, `{string S}`, `{number TEXT}`, `{bool true}` or `{bool false}`, and `null`. A number keeps its text. `encode -typed` writes the tree back.}
            example {ztcl::json parse -typed {{"a": [1, "x", true, null]}}} {object {a {array {{number 1} {string x} {bool true} null}}}}
            error {ztcl::json parse -bogus x} {bad option "-bogus": must be -null, -typed, or --} {ZT JSON OPTION}
        }
        option -- {
            type flag
            summary {Ends the options.}
            description {The next argument is TEXT, also when it starts with `-`.}
            example {ztcl::json parse -- {"x"}} x
            noerrors {A flag has no value to check.}
        }
    }

    subcommand valid {
        synopsis {ztcl::json valid TEXT}
        summary {Tests whether a text is valid JSON.}
        description {Gives 1 when TEXT is one valid JSON value of RFC 8259, with optional white space around it, else 0. The numbers `1.` and `.1` are not valid.}
        returns {1 or 0.}
        see {{ztcl::json parse}}
        argument TEXT {
            type string
            summary {The text to test.}
        }
        example {ztcl::json valid {{"a": 1}}} 1
        example {ztcl::json valid {[1,}} 0
        example {ztcl::json valid {1.}} 0
        error {ztcl::json valid} {wrong # args: should be "ztcl::json valid text"} {TCL WRONGARGS}
    }

    subcommand get {
        synopsis {ztcl::json get ?-null VALUE? ?--? TEXT ?STEP ...?}
        summary {Gives the value at a path of a JSON text, with no full parse.}
        description {
            Walks TEXT along the STEP arguments and gives the Tcl value at the end of the path, as `parse` gives it. A step is a key of an object or a decimal index of an array. With no STEP it gives the value of the whole text.

            The walk makes only the value at the end of the path. It checks the brackets of each value that it skips, and does not check the scalars in them, so `get` can read a text that `valid` rejects. A path with no value is an error with the code `ZT JSON PATH`, and a `null` at the end needs `-null`.
        }
        returns {The Tcl value at the path.}
        see {{ztcl::json exists} {ztcl::json parse} {dict get}}
        argument TEXT {
            type {JSON text}
            summary {The text.}
        }
        argument STEP {
            type {key or index}
            optional
            repeats
            summary {A key of an object, or an index of an array.}
        }
        example {ztcl::json get {{"a": {"b": [10, 20]}}} a b 1} 20
        example {ztcl::json get {{"a": {"b": [10, 20]}}} a} {b {10 20}}
        example {ztcl::json get {{"a": 1}}} {a 1}
        error {ztcl::json get {{"a": 1}} z} {json path "z" has no value} {ZT JSON PATH}
        error {ztcl::json get {[1, 2]} 5} {json path "5" has no value} {ZT JSON PATH}
        option -null {
            value VALUE
            type string
            summary {Gives the value of a JSON null.}
            description {A `null` at the end of the path, or in the value there, becomes VALUE.}
            example {ztcl::json get -null N {{"a": null}} a} N
            error {ztcl::json get {{"a": null}} a} {json syntax error at line 1, column 7: null needs the option -null} {ZT JSON NULL}
        }
        option -- {
            type flag
            summary {Ends the options.}
            description {The next argument is TEXT, also when it starts with `-`.}
            example {ztcl::json get -- {[5]} 0} 5
            noerrors {A flag has no value to check.}
        }
    }

    subcommand exists {
        synopsis {ztcl::json exists TEXT ?STEP ...?}
        summary {Tests whether a path of a JSON text has a value.}
        description {Gives 1 when the path of STEP arguments has a value in TEXT, else 0, with the walk of `get`.}
        returns {1 or 0.}
        see {{ztcl::json get} {dict exists}}
        argument TEXT {
            type {JSON text}
            summary {The text.}
        }
        argument STEP {
            type {key or index}
            optional
            repeats
            summary {A key of an object, or an index of an array.}
        }
        example {ztcl::json exists {{"a": {"b": 1}}} a b} 1
        example {ztcl::json exists {{"a": 1}} z} 0
        example {ztcl::json exists {[1, 2]} 1} 1
        error {ztcl::json exists} {wrong # args: should be "ztcl::json exists text ?step ...?"} {TCL WRONGARGS}
    }

    subcommand encode {
        synopsis {ztcl::json encode -schema SCHEMA VALUE}
        synopsis {ztcl::json encode -typed TREE}
        synopsis {ztcl::json encode -auto VALUE}
        summary {Writes a Tcl value as JSON text, with a schema or a typed tree.}
        description {
            A Tcl value has no visible type, so `encode` needs to be told the JSON type of each part: a schema with `-schema`, a typed tree of `parse -typed` with `-typed`, or a guess for each value with `-auto`. The text has no spaces.

            A schema is one of these words: `string`, `int` (also above 64 bits), `number` (Inf and NaN are errors), `bool` (from each boolean of Tcl), `null`, `raw` (the value is JSON text, with no check), `object` (a dict with a guess for each value), `{object SCHEMA}` (a dict with a schema for each key, in that order), `{list WORD}` (a list with WORD for each element), and `{optional WORD}` (in an object schema: the key can be absent).

            A guess makes a number of the canonical text of an integer or a double, a bool of `true` and `false`, and a string of each other value. In `{object SCHEMA}` a missing key and a key that SCHEMA does not name are errors.
        }
        returns {The JSON text.}
        see {{ztcl::json parse} {ztcl::json object}}
        example {ztcl::json encode -schema {object {n int s string}} {n 5 s hi}} {{"n":5,"s":"hi"}}
        example {ztcl::json encode -schema {list int} {1 2 3}} {[1,2,3]}
        example {ztcl::json encode -schema {object {a {optional int}}} {}} {{}}
        example {ztcl::json encode -schema string 5} {"5"}
        error {ztcl::json encode -schema {object {n int}} {}} {missing key "n"} {ZT JSON SCHEMA}
        error {ztcl::json encode -schema {object {n int}} {n 5 m 6}} {key "m" is not in the schema} {ZT JSON SCHEMA}
        error {ztcl::json encode x} {wrong # args: should be "ztcl::json encode -schema schema value | -typed tree | -auto value"} {TCL WRONGARGS}
        option -schema {
            value SCHEMA
            type schema
            summary {Writes VALUE with the JSON types of a schema.}
            description {Writes VALUE with the schema words above. A value that does not fit its word is an error with the code `ZT JSON VALUE`, and a word that is not a schema is an error with the code `ZT JSON SCHEMA`.}
            example {ztcl::json encode -schema bool yes} true
            example {ztcl::json encode -schema object {a 1 b x c true}} {{"a":1,"b":"x","c":true}}
            error {ztcl::json encode -schema int x} {expected an integer but got "x"} {ZT JSON VALUE}
            error {ztcl::json encode -schema number inf} {json has no number "inf"} {ZT JSON VALUE}
            error {ztcl::json encode -schema bogus 1} {bad schema "bogus"} {ZT JSON SCHEMA}
        }
        option -typed {
            value TREE
            type {typed tree}
            summary {Writes a typed tree of parse -typed.}
            description {Writes TREE, a tree of `{object ...}`, `{array ...}`, `{string S}`, `{number TEXT}`, `{bool B}`, and `null`, as `parse -typed` gives it.}
            example {ztcl::json encode -typed {object {a {number 1} b {string x}}}} {{"a":1,"b":"x"}}
            error {ztcl::json encode -typed {bogus 1}} {bad typed value "bogus 1"} {ZT JSON TYPED}
        }
        option -auto {
            value VALUE
            type dict
            summary {Writes a dict with a guess for each value; the same as -schema object.}
            description {`-auto VALUE` is `-schema object VALUE`: VALUE is a dict, and each value gets the guess above.}
            example {ztcl::json encode -auto {a 1 b x}} {{"a":1,"b":"x"}}
            error {ztcl::json encode -auto {a}} {missing value to go with key} {TCL VALUE DICTIONARY}
        }
    }

    subcommand object {
        synopsis {ztcl::json object ?KEY JSON ...?}
        summary {Writes a JSON object from keys and JSON values.}
        description {Gives a JSON object with each KEY and its value. Each value is JSON text, such as the result of another builder, and goes in as it is. With no argument it gives `{}`.}
        returns {The JSON text.}
        see {{ztcl::json array} {ztcl::json encode}}
        argument KEY {
            type string
            optional
            repeats
            summary {A key.}
        }
        argument JSON {
            type {JSON text}
            optional
            repeats
            summary {The value of the key before it.}
        }
        example {ztcl::json object a [ztcl::json number 1] b [ztcl::json string x]} {{"a":1,"b":"x"}}
        example {ztcl::json object} {{}}
        error {ztcl::json object a} {wrong # args: should be "ztcl::json object ?key json ...?"} {TCL WRONGARGS}
    }

    subcommand array {
        synopsis {ztcl::json array ?JSON ...?}
        summary {Writes a JSON array from JSON values.}
        description {Gives a JSON array of each JSON argument, in order. Each one is JSON text and goes in as it is. With no argument it gives `[]`.}
        returns {The JSON text.}
        see {{ztcl::json object}}
        argument JSON {
            type {JSON text}
            optional
            repeats
            summary {An element.}
        }
        example {ztcl::json array 1 [ztcl::json bool yes]} {[1,true]}
        example {ztcl::json array} {[]}
        noerrors {Each count of arguments is valid, and the builder does not check the JSON text of its elements.}
    }

    subcommand string {
        synopsis {ztcl::json string S}
        summary {Writes a JSON string.}
        description {Gives S as a JSON string in quotes, with the escapes that JSON needs, such as `\"` for a quote.}
        returns {The JSON text.}
        see {{ztcl::json number}}
        argument S {
            type string
            summary {The text.}
        }
        example {ztcl::json string "a\"b"} {"a\"b"}
        error {ztcl::json string} {wrong # args: should be "ztcl::json string s"} {TCL WRONGARGS}
    }

    subcommand number {
        synopsis {ztcl::json number N}
        summary {Writes a JSON number.}
        description {Gives N as a JSON number. N must be a number of Tcl, and Inf and NaN are errors.}
        returns {The JSON text.}
        see {{ztcl::json string}}
        argument N {
            type number
            summary {The number.}
        }
        example {ztcl::json number 1.5} 1.5
        error {ztcl::json number x} {expected a number but got "x"} {ZT JSON VALUE}
        error {ztcl::json number inf} {json has no number "inf"} {ZT JSON VALUE}
    }

    subcommand bool {
        synopsis {ztcl::json bool B}
        summary {Writes a JSON true or false.}
        description {Gives `true` or `false` from B, a boolean of Tcl such as `1`, `yes`, or `off`.}
        returns {true or false.}
        see {{ztcl::json null}}
        argument B {
            type boolean
            summary {The boolean.}
        }
        example {ztcl::json bool yes} true
        error {ztcl::json bool maybe} {expected a boolean but got "maybe"} {ZT JSON VALUE}
    }

    subcommand null {
        synopsis {ztcl::json null}
        summary {Writes a JSON null.}
        description {Gives the text `null`.}
        returns {null.}
        see {{ztcl::json bool}}
        example {ztcl::json null} null
        error {ztcl::json null x} {wrong # args: should be "ztcl::json null"} {TCL WRONGARGS}
    }

    subcommand raw {
        synopsis {ztcl::json raw JSON}
        summary {Checks a JSON text and gives it as it is.}
        description {Gives JSON with no change after a check that it is valid JSON, for a value of `object` or `array` that comes from elsewhere.}
        returns {The JSON text.}
        see {{ztcl::json valid}}
        argument JSON {
            type {JSON text}
            summary {The text.}
        }
        example {ztcl::json raw {[1, 2]}} {[1, 2]}
        error {ztcl::json raw {[1,}} {json syntax error at line 1, column 4: value expected} {ZT JSON SYNTAX 1 4}
    }

    subcommand pretty {
        synopsis {ztcl::json pretty ?-indent N? TEXT}
        summary {Lays out a JSON text with one member on each line.}
        description {Gives TEXT with one member or element on each line, N spaces for each level, and `: ` after each key. An empty object stays `{}`. TEXT must be valid JSON.}
        returns {The JSON text.}
        see {{ztcl::json valid}}
        argument TEXT {
            type {JSON text}
            summary {The text.}
        }
        example {ztcl::json pretty {{"a":[1,2],"b":{}}}} "\{\n  \"a\": \[\n    1,\n    2\n  \],\n  \"b\": \{\}\n\}"
        error {ztcl::json pretty {[1,}} {json syntax error at line 1, column 4: value expected} {ZT JSON SYNTAX 1 4}
        option -indent {
            value N
            type integer
            default 2
            summary {The count of spaces for each level.}
            description {Each level of nesting gets N more spaces.}
            example {ztcl::json pretty -indent 4 {{"a":1}}} "\{\n    \"a\": 1\n\}"
            error {ztcl::json pretty -indent x {{}}} {expected an integer but got "x"} {ZT JSON OPTION}
        }
    }
}
