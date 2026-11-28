# Converted by tools/refdoc.tcl convert from dicts.txt.

command dict {
    area dicts
    since TODO
    synopsis {dict subcommand ?arg ...?}
    summary {The commands for dicts.}
    description {The commands for dicts. A dict is a list of keys and values with each key once. It keeps the order in which the keys came in. A path of keys goes into nested dicts.}
    example {set d [dict create text milk done 0]} {text milk done 0}
    example {dict get $d text} milk
    example {dict set d done 1} {text milk done 1}
    example {dict exists $d tags} 0
    example {dict merge {a 1 b 2} {b 3}} {a 1 b 3}
    example {dict filter {a 1 b 2 c 3} value {[13]}} {a 1 c 3}
    error {dict get {a 1} b} {key "b" not known in dictionary} NONE
    subcommand create {
        synopsis {dict create ?KEY VALUE ...?}
        summary {A new dict.}
        description {A new dict.}
    }
    subcommand get {
        synopsis {dict get DICT ?KEY ...?}
        summary {The value at the path of keys.}
        description {The value at the path of keys. A missing key is an error. With no key, the whole dict.}
    }
    subcommand getdef {
        synopsis {dict getdef DICT ?KEY ...? KEY DEFAULT}
        summary {The value at the path of keys, or DEFAULT when a key is missing.}
        description {The value at the path of keys, or DEFAULT when a key is missing. `dict getwithdefault` is the same command.}
        tcl 9.1
    }
    subcommand getwithdefault {
        synopsis {dict getwithdefault DICT ?KEY ...? KEY DEFAULT}
        summary {The same command as `dict getdef`.}
        description {The same command as `dict getdef`.}
        tcl 9.1
    }
    subcommand exists {
        synopsis {dict exists DICT KEY ?KEY ...?}
        summary {1 when the path of keys exists.}
        description {1 when the path of keys exists.}
    }
    subcommand set {
        synopsis {dict set VAR KEY ?KEY ...? VALUE}
        summary {Sets the value at the path in the dict of a variable, and gives the new dict.}
        description {Sets the value at the path in the dict of a variable, and gives the new dict.}
    }
    subcommand unset {
        synopsis {dict unset VAR KEY ?KEY ...?}
        summary {Removes a key in the dict of a variable.}
        description {Removes a key in the dict of a variable.}
    }
    subcommand keys {
        synopsis {dict keys DICT ?PATTERN?}
        summary {The keys, or the keys that match a glob pattern.}
        description {The keys, or the keys that match a glob pattern.}
    }
    subcommand values {
        synopsis {dict values DICT ?PATTERN?}
        summary {The values.}
        description {The values.}
    }
    subcommand size {
        synopsis {dict size DICT}
        summary {The count of keys.}
        description {The count of keys.}
    }
    subcommand for {
        synopsis {dict for {KEYVAR VALUEVAR} DICT BODY}
        summary {Runs BODY for each key and value.}
        description {Runs BODY for each key and value.}
    }
    subcommand map {
        synopsis {dict map {KEYVAR VALUEVAR} DICT BODY}
        summary {A new dict with the same keys and the results of BODY as values.}
        description {A new dict with the same keys and the results of BODY as values.}
    }
    subcommand filter {
        synopsis {dict filter DICT key|value|script ...}
        summary {The keys and values that match a pattern, or a script that gives true.}
        description {The keys and values that match a pattern, or a script that gives true.}
    }
    subcommand merge {
        synopsis {dict merge ?DICT ...?}
        summary {One dict.}
        description {One dict. A later dict wins for a key in both.}
    }
    subcommand remove {
        synopsis {dict remove DICT ?KEY ...?}
        summary {A copy with no such keys.}
        description {A copy with no such keys.}
    }
    subcommand replace {
        synopsis {dict replace DICT ?KEY VALUE ...?}
        summary {A copy with the new values.}
        description {A copy with the new values.}
    }
    subcommand incr {
        synopsis {dict incr VAR KEY ?INCREMENT?}
        summary {Adds to an integer value in the dict of a variable.}
        description {Adds to an integer value in the dict of a variable.}
    }
    subcommand append {
        synopsis {dict append VAR KEY ?STRING ...?}
        summary {Adds text to a value in the dict of a variable.}
        description {Adds text to a value in the dict of a variable.}
    }
    subcommand lappend {
        synopsis {dict lappend VAR KEY ?VALUE ...?}
        summary {Adds elements to a list value in the dict of a variable.}
        description {Adds elements to a list value in the dict of a variable.}
    }
    subcommand update {
        synopsis {dict update VAR KEY VARNAME ?KEY VARNAME ...? BODY}
        summary {Links variables to keys while BODY runs, and writes them back after it.}
        description {Links variables to keys while BODY runs, and writes them back after it.}
    }
    subcommand with {
        synopsis {dict with VAR ?KEY ...? BODY}
        summary {Makes a variable of each key while BODY runs, and writes them back after it.}
        description {Makes a variable of each key while BODY runs, and writes them back after it.}
    }
    subcommand info {
        synopsis {dict info DICT}
        summary {Text for people with the count of entries of the dict.}
        description {Text for people with the count of entries of the dict. Tcl gives the statistics of its hash table.}
    }
}
