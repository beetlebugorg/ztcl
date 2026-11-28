# The command reference: dict. The format is in
# docs/dev/reference-format.md.

command dict {
    area dicts
    since 1.0.0-beta.1
    synopsis {dict SUBCOMMAND ?ARG ...?}
    summary {The commands for dicts: lists of keys and values with each key once.}
    description {
        The commands for dicts. A dict is a list with an even count of elements: each key followed by its value. Each key is in a dict once, and the dict keeps the order in which the keys came in. A change of the value of a key keeps its place.

        Each argument that is a dict must be a valid list with an even count of elements. In a list with a key twice, the last value is the one of the key, at the place of the first one.

        A path of keys goes into nested dicts: `dict get $d a b` is the value of `b` in the dict that is the value of `a`. The subcommands with VAR in their synopsis change the dict in a variable and give the new dict. The others read a dict value and leave each variable as it is.

        The first argument names the subcommand, and a unique prefix of its name is enough.
    }
    returns {The result of the subcommand.}
    see {array list lsort {string map}}
    release {Tcl 9.1 adds `dict getdef` and its other name `dict getwithdefault`.}
    example {set d [dict create text milk done 0]} {text milk done 0}
    example {dict get $d text} milk
    example {dict set d done 1} {text milk done 1}
    example {dict exists $d tags} 0
    example {dict merge {a 1 b 2} {b 3}} {a 1 b 3}
    example {dict filter {a 1 b 2 c 3} value {[13]}} {a 1 c 3}
    error {dict get {a 1} b} {key "b" not known in dictionary} {TCL LOOKUP DICT b}
    error {dict nope} {unknown or ambiguous subcommand "nope": must be append, create, exists, filter, for, get, getdef, getwithdefault, incr, info, keys, lappend, map, merge, remove, replace, set, size, unset, update, values, or with} {TCL LOOKUP SUBCOMMAND nope} -tcl 9.1
    error {dict nope} {unknown or ambiguous subcommand "nope": must be append, create, exists, filter, for, get, incr, info, keys, lappend, map, merge, remove, replace, set, size, unset, update, values, or with} {TCL LOOKUP SUBCOMMAND nope} -tcl 8.6
    error {dict size "a \{"} {unmatched open brace in dict} {TCL VALUE DICTIONARY BRACE} -note {A value that is not a valid list.}

    subcommand create {
        synopsis {dict create ?KEY VALUE ...?}
        summary {Makes a dict from keys and values.}
        description {
            Gives a new dict with each KEY and its VALUE, in the order of the arguments. A key that comes twice keeps its first place and its last value. With no argument it gives an empty dict. A key can be any string, also an empty one.
        }
        returns {The new dict.}
        see {{dict replace} list}
        argument KEY {
            type string
            summary {A key.}
            optional
            repeats
        }
        argument VALUE {
            type {any value}
            summary {The value of the key before it.}
            optional
            repeats
        }
        example {dict create a 1 b 2} {a 1 b 2}
        example {dict create a 1 b 2 a 3} {a 3 b 2}
        example {dict create} {}
        example {dict create {} x} {{} x}
        error {dict create a} {wrong # args: should be "dict create ?key value ...?"} {TCL WRONGARGS}
    }

    subcommand get {
        synopsis {dict get DICT ?KEY ...?}
        summary {Gives the value at a path of keys.}
        description {
            Gives the value of KEY in DICT. With more than one KEY, each key goes one level down into a nested dict, and the value of the last key is the result. With no KEY it gives DICT as it is, after a check that it is a valid dict.

            A missing key is an error. Use `dict exists` before the call, or `dict getdef` in Tcl 9.1, for a key that can be missing. A value on the path that is not a dict is an error too.
        }
        returns {The value.}
        see {{dict getdef} {dict exists} {dict set} lindex}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument KEY {
            type string
            summary {A key of the path.}
            optional
            repeats
        }
        example {dict get {a 1 b 2} b} 2
        example {dict get {a {x 9}} a x} 9
        example {dict get {a 1 b 2}} {a 1 b 2}
        error {dict get {a 1} b} {key "b" not known in dictionary} {TCL LOOKUP DICT b}
        error {dict get {a 1} a x} {missing value to go with key} {TCL VALUE DICTIONARY} -note {The value 1 of the key a is not a dict.}
        error {dict get} {wrong # args: should be "dict get dictionary ?key ...?"} {TCL WRONGARGS}
    }

    subcommand getdef {
        synopsis {dict getdef DICT ?KEY ...? KEY DEFAULT}
        summary {Gives the value at a path of keys, or a default when a key is missing.}
        description {
            Gives the value at the path of keys in DICT, as `dict get` does. When a key of the path is missing, it gives DEFAULT in place of an error. A value on the path that is not a dict is still an error.

            `dict getwithdefault` is the same command. Both are in Tcl 9.1 only.
        }
        returns {The value, or DEFAULT.}
        tcl 9.1
        see {{dict get} {dict getwithdefault} {dict exists}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument KEY {
            type string
            summary {The keys of the path, at least one.}
            repeats
        }
        argument DEFAULT {
            type {any value}
            summary {The result when a key is missing.}
        }
        example {dict getdef {a 1} b 9} 9
        example {dict getdef {a 1} a 9} 1
        example {dict getdef {a {b 2}} a c 0} 0
        example {dict getdef {} a b 1} 1
        error {dict getdef {a 1} a x 0} {missing value to go with key} {TCL VALUE DICTIONARY}
        error {dict getdef {a 1} b} {wrong # args: should be "dict getdef dictionary ?key ...? key default"} {TCL WRONGARGS}
    }

    subcommand getwithdefault {
        synopsis {dict getwithdefault DICT ?KEY ...? KEY DEFAULT}
        summary {Gives the value at a path of keys, or a default: the same command as dict getdef.}
        description {The same command as `dict getdef`, with a longer name. It is in Tcl 9.1 only.}
        returns {The value, or DEFAULT.}
        tcl 9.1
        see {{dict getdef}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument KEY {
            type string
            summary {The keys of the path, at least one.}
            repeats
        }
        argument DEFAULT {
            type {any value}
            summary {The result when a key is missing.}
        }
        example {dict getwithdefault {a 1} b 9} 9
        error {dict getwithdefault {a 1}} {wrong # args: should be "dict getwithdefault dictionary ?key ...? key default"} {TCL WRONGARGS}
    }

    subcommand exists {
        synopsis {dict exists DICT KEY ?KEY ...?}
        summary {Tests whether a path of keys exists.}
        description {
            Gives 1 when DICT has the path of keys, else 0. A value on the path that is not a dict gives 0, and so does a DICT that is not a valid dict: the command never fails on its values.
        }
        returns {1 or 0.}
        see {{dict get} {dict getdef} {info exists}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument KEY {
            type string
            summary {The keys of the path, at least one.}
            repeats
        }
        example {dict exists {a 1} a} 1
        example {dict exists {a {b 2}} a b} 1
        example {dict exists {a 1} a b} 0
        example {dict exists {a 1 b} a} 0 -note {A list with an odd count of elements is not a dict.}
        error {dict exists {a 1}} {wrong # args: should be "dict exists dictionary key ?key ...?"} {TCL WRONGARGS}
    }

    subcommand set {
        synopsis {dict set VAR KEY ?KEY ...? VALUE}
        summary {Sets the value at a path of keys in the dict of a variable.}
        description {
            Sets the value at the path of keys in the dict of the variable VAR to VALUE, and gives the new dict. A new key goes at the end of its dict, and a key that exists keeps its place. A missing key on the path makes a new nested dict.

            A VAR with no value starts as an empty dict. A value of VAR or on the path that is not a dict is an error, and VAR then keeps its value.
        }
        returns {The new value of VAR.}
        see {{dict unset} {dict replace} {dict get} lset}
        argument VAR {
            type {variable name}
            summary {The variable with the dict.}
        }
        argument KEY {
            type string
            summary {The keys of the path, at least one.}
            repeats
        }
        argument VALUE {
            type {any value}
            summary {The new value.}
        }
        example {
            set d {a 1}
            dict set d b 2
        } {a 1 b 2}
        example {
            set d {a {b 1}}
            dict set d a c 2
        } {a {b 1 c 2}}
        example {
            unset -nocomplain e
            dict set e a b c 1
        } {a {b {c 1}}}
        error {
            set d {a 1}
            dict set d a x y
        } {missing value to go with key} {TCL VALUE DICTIONARY} -note {The value 1 of the key a is not a dict.}
        error {dict set d a} {wrong # args: should be "dict set dictVarName key ?key ...? value"} {TCL WRONGARGS}
    }

    subcommand unset {
        synopsis {dict unset VAR KEY ?KEY ...?}
        summary {Removes the key at the end of a path from the dict of a variable.}
        description {
            Removes the last KEY of the path from its dict in the variable VAR, and gives the new dict. A missing last key is no error: the dict stays the same. A missing key before the last one is an error.

            A VAR with no value starts as an empty dict, so the result is an empty dict.
        }
        returns {The new value of VAR.}
        see {{dict set} {dict remove} unset}
        argument VAR {
            type {variable name}
            summary {The variable with the dict.}
        }
        argument KEY {
            type string
            summary {The keys of the path, at least one.}
            repeats
        }
        example {
            set d {a 1 b 2}
            dict unset d a
        } {b 2}
        example {
            set d {a {x 1 y 2}}
            dict unset d a x
        } {a {y 2}}
        example {
            set d {a 1 b 2}
            dict unset d zz
        } {a 1 b 2}
        error {
            set d {a 1}
            dict unset d q r
        } {key "q" not known in dictionary} {TCL LOOKUP DICT q}
        error {dict unset d} {wrong # args: should be "dict unset dictVarName key ?key ...?"} {TCL WRONGARGS}
    }

    subcommand keys {
        synopsis {dict keys DICT ?PATTERN?}
        summary {Gives the keys of a dict, or the keys that match a glob pattern.}
        description {
            Gives a list of the keys of DICT in their order. With PATTERN it gives only the keys that match it, with the rules of `string match`.
        }
        returns {A list of keys.}
        see {{dict values} {dict filter} {array names} {string match}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument PATTERN {
            type {glob pattern}
            summary {A pattern for the keys.}
            optional
        }
        example {dict keys {a 1 b 2 ab 3}} {a b ab}
        example {dict keys {a 1 b 2 ab 3} a*} {a ab}
        example {dict keys {}} {}
        error {dict keys {a 1 b}} {missing value to go with key} {TCL VALUE DICTIONARY}
    }

    subcommand values {
        synopsis {dict values DICT ?PATTERN?}
        summary {Gives the values of a dict, or the values that match a glob pattern.}
        description {
            Gives a list of the values of DICT in the order of their keys. With PATTERN it gives only the values that match it, with the rules of `string match`.
        }
        returns {A list of values.}
        see {{dict keys} {dict filter}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument PATTERN {
            type {glob pattern}
            summary {A pattern for the values.}
            optional
        }
        example {dict values {a 1 b 2 c 12}} {1 2 12}
        example {dict values {a 1 b 2 c 12} 1*} {1 12}
        error {dict values x} {missing value to go with key} {TCL VALUE DICTIONARY}
    }

    subcommand size {
        synopsis {dict size DICT}
        summary {Gives the count of keys of a dict.}
        description {
            Gives the count of keys of DICT. A key that is twice in the list counts once. An empty dict has size 0.
        }
        returns {A non-negative integer.}
        see {llength {array size}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        example {dict size {a 1 b 2}} 2
        example {dict size {a 1 a 2}} 1
        example {dict size {}} 0
        error {dict size {a}} {missing value to go with key} {TCL VALUE DICTIONARY}
        error {dict size} {wrong # args: should be "dict size dictionary"} {TCL WRONGARGS}
    }

    subcommand for {
        synopsis {dict for {KEYVAR VALUEVAR} DICT BODY}
        summary {Runs a script for each key and value of a dict.}
        description {
            Runs BODY once for each key of DICT, in order, with the key in the variable KEYVAR and the value in VALUEVAR. `break` in BODY ends the loop, and `continue` goes on with the next key. An error in BODY ends the loop with that error.

            The loop works on the value of DICT at its start, so a change of a variable in BODY does not change the keys of the loop. The result is an empty string.
        }
        returns {An empty string.}
        see {{dict map} foreach {array for}}
        argument {{KEYVAR VALUEVAR}} {
            type {list of two variable names}
            summary {The variables of the key and of the value.}
        }
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument BODY {
            type script
            summary {The script to run for each key.}
        }
        example {dict for {k v} {a 1 b 2} {puts "$k=$v"}} {} -output "a=1\nb=2\n"
        example {dict for {k v} {a 1 b 2 c 3} {if {$k eq "b"} continue; puts $k}} {} -output "a\nc\n"
        example {dict for {k v} {a 1 b 2} {if {$k eq "b"} break; puts $k}} {} -output "a\n"
        error {dict for {k} {a 1} {}} {must have exactly two variable names} {TCL SYNTAX dict for}
        error {dict for {k v} {a 1} {error boom}} boom NONE
    }

    subcommand map {
        synopsis {dict map {KEYVAR VALUEVAR} DICT BODY}
        summary {Makes a dict with the same keys and the results of a script as values.}
        description {
            Runs BODY once for each key of DICT, as `dict for` does, and gives a new dict: each key with the result of BODY as its value. The key of the result is the value of KEYVAR after BODY, so BODY can change the key: a key that BODY gives twice keeps the last value.

            `continue` in BODY leaves the key out of the result. `break` ends the loop and gives an empty dict.
        }
        returns {The new dict.}
        see {{dict for} lmap {dict filter}}
        argument {{KEYVAR VALUEVAR}} {
            type {list of two variable names}
            summary {The variables of the key and of the value.}
        }
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument BODY {
            type script
            summary {The script that gives each new value.}
        }
        example {dict map {k v} {a 1 b 2} {expr {$v * 10}}} {a 10 b 20}
        example {dict map {k v} {a 1 b 2 c 3} {if {$k eq "b"} continue; set v}} {a 1 c 3}
        example {dict map {k v} {a 1 b 2 c 3} {if {$k eq "b"} break; set v}} {}
        example {dict map {k v} {a 1} {set k z; set v}} {z 1}
        example {dict map {k v} {a 1 b 2} {set k z; set v}} {z 2} -note {Both keys become `z`, and the last value stays.}
        error {dict map {k} {a 1} {}} {must have exactly two variable names} {TCL SYNTAX dict map}
        error {dict map {k v} {a 1} {error inner}} inner NONE
    }

    subcommand filter {
        synopsis {dict filter DICT key ?PATTERN ...?}
        synopsis {dict filter DICT value ?PATTERN ...?}
        synopsis {dict filter DICT script {KEYVAR VALUEVAR} BODY}
        summary {Gives the keys and values of a dict that pass a test.}
        description {
            Gives a new dict with the keys and values of DICT that pass the test of the filter type, in their order.

            - `key`: the key matches at least one PATTERN, with the rules of `string match`. With no PATTERN the result is an empty dict.
            - `value`: the value matches at least one PATTERN.
            - `script`: BODY runs for each key and value, with KEYVAR and VALUEVAR set, and its result must be a boolean. A true result keeps the key. `break` ends the loop and gives the keys kept so far, and `continue` leaves the key out.

            A unique prefix of a filter type is the type.
        }
        returns {The new dict.}
        see {{dict keys} {dict values} {dict map} lsearch}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument {key|value|script} {
            type {filter type}
            summary {The kind of test.}
            choice key {Tests each key against the patterns.}
            choice value {Tests each value against the patterns.}
            choice script {Runs BODY for each key and value.}
        }
        argument PATTERN {
            type {glob pattern}
            summary {A pattern of the type key or value.}
            optional
            repeats
        }
        argument BODY {
            type script
            summary {The test of the type script, with its two variables.}
        }
        example {dict filter {a 1 b 2 ab 3} key a*} {a 1 ab 3}
        example {dict filter {a 1 b 2 ab 3} key a* b} {a 1 b 2 ab 3}
        example {dict filter {a 1 b 2 c 3} value {[13]}} {a 1 c 3}
        example {dict filter {a 1 b 2 c 3} script {k v} {expr {$v > 1}}} {b 2 c 3}
        example {dict filter {a 1 b 2 c 3} script {k v} {if {$v == 2} break; expr 1}} {a 1}
        error {dict filter {a 1} bogus x} {bad filterType "bogus": must be key, script, or value} {TCL LOOKUP INDEX filterType bogus}
        error {dict filter {a 1} script {k v} {expr {"x"}}} {expected boolean value but got "x"} {TCL VALUE NUMBER}
    }

    subcommand merge {
        synopsis {dict merge ?DICT ...?}
        summary {Joins dicts into one, with the value of a later dict for a key in both.}
        description {
            Gives one dict with each key of each DICT. For a key in more than one DICT, the value of the last one wins, and the key keeps the place of its first one. The merge is one level deep: a nested dict is a value, and a later one replaces it as a whole. With no DICT it gives an empty dict.
        }
        returns {The new dict.}
        see {{dict replace} {dict create}}
        argument DICT {
            type dict
            summary {A dict to join.}
            optional
            repeats
        }
        example {dict merge {a 1 b 2} {b 3 c 4}} {a 1 b 3 c 4}
        example {dict merge {a {x 1}} {a {y 2}}} {a {y 2}}
        example {dict merge} {}
        error {dict merge {a 1} {b}} {missing value to go with key} {TCL VALUE DICTIONARY}
    }

    subcommand remove {
        synopsis {dict remove DICT ?KEY ...?}
        summary {Gives a copy of a dict with some keys removed.}
        description {
            Gives DICT with no KEY in it. A KEY that is not in DICT is no error. The keys are of the top level only: there is no path.
        }
        returns {The new dict.}
        see {{dict unset} {dict filter}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument KEY {
            type string
            summary {A key to remove.}
            optional
            repeats
        }
        example {dict remove {a 1 b 2 c 3} a c} {b 2}
        example {dict remove {a 1} zz} {a 1}
        error {dict remove {a}} {missing value to go with key} {TCL VALUE DICTIONARY}
    }

    subcommand replace {
        synopsis {dict replace DICT ?KEY VALUE ...?}
        summary {Gives a copy of a dict with new values for some keys.}
        description {
            Gives DICT with each KEY set to its VALUE. A key that exists keeps its place, and a new key goes at the end. The keys are of the top level only. With no KEY it gives DICT.
        }
        returns {The new dict.}
        see {{dict set} {dict merge}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        argument KEY {
            type string
            summary {A key.}
            optional
            repeats
        }
        argument VALUE {
            type {any value}
            summary {The new value of the key before it.}
            optional
            repeats
        }
        example {dict replace {a 1 b 2} b 3 c 4} {a 1 b 3 c 4}
        example {dict replace {} a 1} {a 1}
        error {dict replace {a 1} b} {wrong # args: should be "dict replace dictionary ?key value ...?"} {TCL WRONGARGS}
    }

    subcommand incr {
        synopsis {dict incr VAR KEY ?INCREMENT?}
        summary {Adds an integer to the value of a key in the dict of a variable.}
        description {
            Adds INCREMENT to the integer value of KEY in the dict of the variable VAR, and gives the new dict. INCREMENT is 1 by default, and it can be negative or in any integer form, such as `0x10`. A missing key gets INCREMENT as written, so `0x10` stays `0x10`, and a VAR with no value starts as an empty dict. The sum has no size limit: it does not wrap at 64 bits.

            The value of the key and INCREMENT must be integers.
        }
        returns {The new value of VAR.}
        see {incr {dict set} {dict append}}
        argument VAR {
            type {variable name}
            summary {The variable with the dict.}
        }
        argument KEY {
            type string
            summary {The key of the integer.}
        }
        argument INCREMENT {
            type integer
            default 1
            summary {The amount to add.}
            optional
        }
        example {
            set d {n 1}
            dict incr d n
        } {n 2}
        example {
            set d {n 1}
            dict incr d n -2
        } {n -1}
        example {
            set d {}
            dict incr d m 0x10
        } {m 0x10}
        example {
            set d {m 0x10}
            dict incr d m
        } {m 17}
        example {
            set d {n 1}
            dict incr d n 9223372036854775807
        } {n 9223372036854775808}
        error {
            set d {n x}
            dict incr d n
        } {expected integer but got "x"} {TCL VALUE NUMBER}
        error {
            set d {n 1}
            dict incr d n 1.5
        } {expected integer but got "1.5"} {TCL VALUE INTEGER}
    }

    subcommand append {
        synopsis {dict append VAR KEY ?STRING ...?}
        summary {Adds text to the end of the value of a key in the dict of a variable.}
        description {
            Adds each STRING to the end of the value of KEY in the dict of the variable VAR, with no separator, and gives the new dict. A missing key starts as an empty string, and a VAR with no value starts as an empty dict. With no STRING the key gets an empty value when it is missing.
        }
        returns {The new value of VAR.}
        see {append {dict lappend}}
        argument VAR {
            type {variable name}
            summary {The variable with the dict.}
        }
        argument KEY {
            type string
            summary {The key of the text.}
        }
        argument STRING {
            type string
            summary {Text to add.}
            optional
            repeats
        }
        example {
            set d {s ab}
            dict append d s c d
        } {s abcd}
        example {
            set d {}
            dict append d s x
        } {s x}
        error {dict append d} {wrong # args: should be "dict append dictVarName key ?value ...?"} {TCL WRONGARGS}
    }

    subcommand lappend {
        synopsis {dict lappend VAR KEY ?VALUE ...?}
        summary {Adds elements to the list value of a key in the dict of a variable.}
        description {
            Adds each VALUE as one element to the end of the list that is the value of KEY in the dict of the variable VAR, and gives the new dict. A missing key starts as an empty list, and a VAR with no value starts as an empty dict. The value of the key must be a valid list.
        }
        returns {The new value of VAR.}
        see {lappend {dict append}}
        argument VAR {
            type {variable name}
            summary {The variable with the dict.}
        }
        argument KEY {
            type string
            summary {The key of the list.}
        }
        argument VALUE {
            type {any value}
            summary {An element to add.}
            optional
            repeats
        }
        example {
            set d {l {a b}}
            dict lappend d l c {d e}
        } {l {a b c {d e}}}
        example {
            set d {}
            dict lappend d l x
        } {l x}
        error {
            set d {l "a \{"}
            dict lappend d l x
        } {unmatched open brace in list} {TCL VALUE LIST BRACE}
    }

    subcommand update {
        synopsis {dict update VAR KEY VARNAME ?KEY VARNAME ...? BODY}
        summary {Runs a script with variables linked to keys of the dict of a variable.}
        description {
            Sets each VARNAME to the value of its KEY in the dict of the variable VAR, runs BODY, and then writes each VARNAME back to its key. A VARNAME of a missing key has no value at the start. A VARNAME with no value at the end removes its key from the dict.

            The write back happens also when BODY ends with an error. The result is the result of BODY.
        }
        returns {The result of BODY.}
        see {{dict with} upvar}
        argument VAR {
            type {variable name}
            summary {The variable with the dict.}
        }
        argument KEY {
            type string
            summary {A key of the dict.}
            repeats
        }
        argument VARNAME {
            type {variable name}
            summary {The variable for the key before it.}
            repeats
        }
        argument BODY {
            type script
            summary {The script.}
        }
        example {
            set d {a 1 b 2}
            dict update d a x b y {incr x; set y z}
            set d
        } {a 2 b z}
        example {
            set d {a 1}
            dict update d q v {set v new}
            set d
        } {a 1 q new}
        example {
            set d {a 1}
            dict update d a v {unset v}
            set d
        } {}
        example {
            set d {a 1}
            dict update d a v {string length done}
        } 4
        error {dict update d a v b {}} {wrong # args: should be "dict update dictVarName key varName ?key varName ...? script"} {TCL WRONGARGS}
    }

    subcommand with {
        synopsis {dict with VAR ?KEY ...? BODY}
        summary {Runs a script with a variable for each key of the dict of a variable.}
        description {
            Makes a variable for each key of the dict in the variable VAR, with the value of the key, and runs BODY. After BODY, the value of each of those variables goes back to its key, and a variable with no value removes its key. A new variable of BODY does not go into the dict.

            With a path of KEY arguments, the dict at the end of the path is the one with the variables, and the write back goes to that place.

            The write back happens also when BODY ends with an error. The result is the result of BODY.
        }
        returns {The result of BODY.}
        see {{dict update} upvar}
        argument VAR {
            type {variable name}
            summary {The variable with the dict.}
        }
        argument KEY {
            type string
            summary {A key of a path to a nested dict.}
            optional
            repeats
        }
        argument BODY {
            type script
            summary {The script.}
        }
        example {
            set d {a 1 b 2}
            dict with d {incr a; set b x}
            set d
        } {a 2 b x}
        example {
            set d {p {x 1 y 2}}
            dict with d p {set x 5}
            set d
        } {p {x 5 y 2}}
        example {
            set d {a 1}
            dict with d {set z 9}
            set d
        } {a 1}
        example {
            set d {a 1}
            catch {dict with d {set a 2; error oops}}
            set d
        } {a 2}
        error {
            set d {p {x 1}}
            dict with d q {set y 2}
        } {key "q" not known in dictionary} {TCL LOOKUP DICT q}
        error {
            unset -nocomplain nod
            dict with nod {}
        } {can't read "nod": no such variable} {TCL LOOKUP VARNAME nod}
    }

    subcommand info {
        synopsis {dict info DICT}
        summary {Gives text for people with the count of entries of a dict.}
        description {
            Gives a line of text with the count of keys of DICT, such as `2 entries in table`. Tcl gives the statistics of its hash table here. The text is for people: a script uses `dict size` for the count.
        }
        returns {A line of text.}
        see {{dict size} {array statistics}}
        argument DICT {
            type dict
            summary {The dict.}
        }
        example {dict info {a 1 b 2}} {2 entries in table}
        example {dict info {}} {0 entries in table}
        error {dict info {a}} {missing value to go with key} {TCL VALUE DICTIONARY}
    }
}
