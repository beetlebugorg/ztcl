# The command reference: ztcl::probe. The format is in
# docs/dev/reference-format.md.

command ztcl::probe {
    area ztcl
    since 1.0.0-beta.1
    setup {
        package require ztcl::probe
        proc f {n} {
            set x [string repeat a $n]
            return [g $n]
        }
        proc g {n} { return $n }
    }
    synopsis {ztcl::probe SUBCOMMAND ?ARG ...?}
    summary {Records the values of a running script at a proc, a line, a command, a variable, or an error.}
    description {
        The probes of a running script: each probe has a target, a proc, a line of a proc body, a command, a variable, or each error, and each time the target runs, the probe can test a condition and capture values, with no change to the code of the script. The records go in a ring buffer, and `records` gives them back as Tcl dicts or as lines of JSON. [Debugging](debugging/) has `ztcl debug`, which runs a script with probes and writes a report.

        Load the module with `package require ztcl::probe`. It needs no capability, reads no file, and gives a script no access to the host. It is in each native build and in the WebAssembly shell of the site, and `ztcl.wasm` leaves it out.

        A probe uses no compute units of the script: the condition and the captures run with their own budget, and an error of either goes in the record or in the count of errors, so the result, the error state, and `errorInfo` of the script stay the same. A probe on a proc or a line compiles the body of that proc again with probe instructions at its next call, and that body runs in the bytecode interpreter. The records are in the memory of the embedder, outside the memory limit of the script. A probe does not run inside another probe, and `reset` and `compact` of the embedder remove each probe and each record.

        A subcommand has no short form. Most errors of the module have `-errorcode NONE` ([issue 723](https://github.com/beetlebugorg/ztcl/issues/723)). The setup of the examples makes the procs `f`, whose line 2 sets `x` and whose line 3 calls `g`, and `g`.
    }
    returns {The result of the subcommand.}
    page modules/probe/
    see {trace {info frame} {info level}}
    example {
        set p [ztcl::probe add -proc g -capture n]
        f 3
        dict get [lindex [ztcl::probe records -probe $p] 0] values
    } {n 3}
    error {ztcl::probe bogus} {unknown subcommand "bogus": must be add, clear, configure, list, records, or remove} {TCL LOOKUP SUBCOMMAND bogus}
    error {ztcl::probe a -proc f} {unknown subcommand "a": must be add, clear, configure, list, records, or remove} {TCL LOOKUP SUBCOMMAND a}
    error {ztcl::probe} {wrong # args: should be "ztcl::probe add|configure|clear|list|records|remove ?arg ...?"} {TCL WRONGARGS}

    subcommand add {
        synopsis {ztcl::probe add -proc NAME ?-line N? ?OPTION VALUE ...?}
        synopsis {ztcl::probe add -command NAME ?-leave? ?OPTION VALUE ...?}
        synopsis {ztcl::probe add -var NAME ?-ops LIST? ?OPTION VALUE ...?}
        synopsis {ztcl::probe add -error ?OPTION VALUE ...?}
        summary {Adds a probe and gives its id.}
        description {
            Adds a probe on one target and gives its id, such as `p1`. The target is `-proc`, `-command`, `-var`, or `-error`; a second target replaces the first with no error ([issue 723](https://github.com/beetlebugorg/ztcl/issues/723)).

            A probe on a proc or a line waits when no proc has the name, and a new `proc` of the name gets the probe. A probe on a variable makes the variable as `trace add variable` does, and an `unset` of the variable removes the probe from it, so `list` then shows the state `waiting`.
        }
        returns {The id of the probe.}
        see {{ztcl::probe records} {ztcl::probe remove}}
        example {string match p* [ztcl::probe add -proc f]} 1
        example {
            set p [ztcl::probe add -proc h]
            proc h {} { return 1 }
            h
            list [dict get [lindex [ztcl::probe list] end] state] [dict get [lindex [ztcl::probe records -probe $p] 0] words]
        } {active h}
        error {ztcl::probe add} {wrong # args: should be "ztcl::probe add -proc name ?-line n? | -command name | -var name | -error ?option value ...?"} {TCL WRONGARGS}
        error {ztcl::probe add -line 2} {wrong # args: should be "ztcl::probe add -proc name ?-line n? | -command name | -var name | -error ?option value ...?"} {TCL WRONGARGS}
        error {ztcl::probe add -proc f -bogus 1} {bad option "-bogus": must be -capture, -command, -count, -error, -every, -if, -leave, -line, -locals, -ops, -proc, -rate, -stack, or -var} {TCL LOOKUP INDEX option}
        error {ztcl::probe add -bogus} {bad option "-bogus": must be -capture, -command, -count, -error, -every, -if, -leave, -line, -locals, -ops, -proc, -rate, -stack, or -var} {TCL LOOKUP INDEX option}
        option -proc {
            value NAME
            type {proc name}
            summary {Records at each call of a proc.}
            description {Records at each call of the proc NAME, before the first command of the body. The record has the field `words`, the words of the call.}
            example {
                set p [ztcl::probe add -proc g]
                f 1; f 2
                lmap r [ztcl::probe records -probe $p] {dict get $r words}
            } {{g 1} {g 2}}
            error {ztcl::probe add -proc} {option "-proc" needs a value} {TCL VALUE}
        }
        option -line {
            value N
            type integer
            summary {Records before a line of the body of the proc.}
            description {With `-proc`, records before the first command of line N of the body, each time it runs. Line 1 is the text after the open brace, as in the error trace. A command inside it on the same line, such as `incr n` in `if {$x} {incr n}`, does not run the probe again. The probe finds the commands of the body, of the bodies of `if`, `while`, `for`, `foreach`, and `switch`, and of each braced word with a space or a newline; a script made at run time, such as the text of `eval $cmd`, gets no line probe. The record has the field `line`.}
            example {
                set p [ztcl::probe add -proc f -line 3 -capture x]
                f 2
                set r [lindex [ztcl::probe records -probe $p] 0]
                list [dict get $r kind] [dict get $r line] [dict get $r values]
            } {line 3 {x aa}}
            error {ztcl::probe add -proc f -line x} {expected integer but got "x"} {TCL VALUE NUMBER}
            error {ztcl::probe add -proc f -line -1} {-line must be 1 or more} {TCL VALUE}
        }
        option -command {
            value NAME
            type {command name}
            summary {Records at each call of a command.}
            description {Records at each call of the command NAME, with the field `words`. A proc gets the probe of `-proc`. A probe on a command that is not a proc uses the wrapper of the execution traces, and a probe on an inlined core command, such as `set` or `string`, turns the inline forms off while it exists.}
            example {
                set p [ztcl::probe add -command string]
                string length abc
                dict get [lindex [ztcl::probe records -probe $p] 0] words
            } {string length abc}
            error {ztcl::probe add -command} {option "-command" needs a value} {TCL VALUE}
        }
        option -leave {
            type flag
            summary {Records at the return of the command.}
            description {With `-command`, records at the return of the command, with the fields `code` and `result`.}
            example {
                set p [ztcl::probe add -command string -leave]
                string length abc
                set r [lindex [ztcl::probe records -probe $p] 0]
                list [dict get $r code] [dict get $r result]
            } {0 3}
            error {ztcl::probe add -proc f -leave} {-leave needs -command} {TCL VALUE}
        }
        option -var {
            value NAME
            type {variable name}
            summary {Records at each operation on a variable.}
            description {Records at each operation of `-ops` on the global or namespace variable NAME. A name with no `::` is in the current namespace. The record has the fields `var`, `op`, and `value`.}
            example {
                set p [ztcl::probe add -var ::v]
                set v 5
                set r [lindex [ztcl::probe records -probe $p] 0]
                list [dict get $r var] [dict get $r op] [dict get $r value]
            } {v write 5}
            example {
                set v 1
                set p [ztcl::probe add -var ::v]
                unset v
                dict get [lindex [ztcl::probe list] end] state
            } waiting
            error {ztcl::probe add -var} {option "-var" needs a value} {TCL VALUE}
        }
        option -ops {
            value LIST
            type {list of read, write, and unset}
            default write
            summary {Gives the operations of the variable to record.}
            description {With `-var`, the operations that make a record: `read`, `write`, and `unset`.}
            example {
                set p [ztcl::probe add -var ::w -ops {write read}]
                set w 5; set y $w
                lmap r [ztcl::probe records -probe $p] {dict get $r op}
            } {write read}
            error {ztcl::probe add -var v -ops bogus} {bad operation "bogus": must be read, unset, or write} {TCL LOOKUP INDEX operation}
        }
        option -error {
            type flag
            summary {Records at the start of each error.}
            description {Records at the start of each error, also an error that `catch` or `try` catches. The record has the fields `cmd`, `message`, and `errorcode`.}
            example {
                set p [ztcl::probe add -error]
                catch {error boom {} {MY CODE}}
                ztcl::probe remove $p
                set r [lindex [ztcl::probe records -probe $p] 0]
                list [dict get $r message] [dict get $r errorcode]
            } {boom {MY CODE}}
            noerrors {A flag has no value to check.}
        }
        option -if {
            value EXPR
            type expression
            summary {Records only when an expression is true.}
            description {The probe records only when EXPR is true. The expression runs in the frame of the target. An error of the expression goes in the field `probe_error` of the record and in the count of errors.}
            example {
                set p [ztcl::probe add -proc g -if {$n % 2 == 0} -capture n]
                f 1; f 2; f 3; f 4
                lmap r [ztcl::probe records -probe $p] {dict get $r values n}
            } {2 4}
            example {
                set p [ztcl::probe add -proc g -if {$n +}]
                g 1
                dict exists [lindex [ztcl::probe records -probe $p] 0] probe_error
            } 1
            error {ztcl::probe add -proc f -if} {option "-if" needs a value} {TCL VALUE}
        }
        option -capture {
            value LIST
            type list
            summary {Gives the values of each record.}
            description {Each word of LIST is a value of the record, in the dict `values`, with the word as its key. A plain name is a variable, and each other word goes through `subst`, so `[llength $l]` and `$a,$b` work. A value of more than `-maxlen` bytes keeps its first bytes and gets the count of all its bytes. An error of a capture is the value `<error: MESSAGE>`.}
            example {
                set p [ztcl::probe add -proc f -line 3 -capture {n [string length $x]}]
                f 4
                dict get [lindex [ztcl::probe records -probe $p] 0] values
            } {n 4 {[string length $x]} 4}
            example {
                set p [ztcl::probe add -proc g -capture {[expr {1/0}]}]
                g 5
                dict get [lindex [ztcl::probe records -probe $p] 0] values
            } {{[expr {1/0}]} {<error: divide by zero>}}
            error {ztcl::probe add -proc f -capture} {option "-capture" needs a value} {TCL VALUE}
        }
        option -stack {
            type flag
            summary {Adds the call stack to each record.}
            description {The record has the field `stack`: one list of words for each frame, the innermost first.}
            example {
                set p [ztcl::probe add -proc g -stack]
                f 1
                dict get [lindex [ztcl::probe records -probe $p] 0] stack
            } {{g 1} {f 1}}
            noerrors {A flag has no value to check.}
        }
        option -locals {
            type flag
            summary {Adds the call stack with the local variables to each record.}
            description {As `-stack`, and each frame is a list of two: the words, and a dict of its local variables. A value has at most `-maxlen` bytes.}
            example {
                set p [ztcl::probe add -proc g -locals]
                f 1
                dict get [lindex [ztcl::probe records -probe $p] 0] stack
            } {{{g 1} {n 1}} {{f 1} {n 1 x a}}}
            noerrors {A flag has no value to check.}
        }
        option -count {
            value N
            type integer
            summary {Gives the most records of the probe.}
            description {The probe makes at most N records. Each later hit counts in `dropped` of `list`.}
            example {
                set p [ztcl::probe add -proc g -count 2]
                f 1; f 2; f 3
                list [llength [ztcl::probe records -probe $p]] [dict get [lindex [ztcl::probe list] end] dropped]
            } {2 1}
            error {ztcl::probe add -proc f -count x} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
        option -every {
            value N
            type integer
            summary {Records each Nth hit.}
            description {The probe records the first hit and then each Nth hit. `-every 0` records each hit, as `-every 1` does ([issue 723](https://github.com/beetlebugorg/ztcl/issues/723)).}
            example {
                set p [ztcl::probe add -proc g -every 2]
                f 1; f 2; f 3; f 4
                lmap r [ztcl::probe records -probe $p] {dict get $r words}
            } {{g 1} {g 3}}
            error {ztcl::probe add -proc f -every x} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
        option -rate {
            value {{N UNITS}}
            type {list of two integers}
            summary {Gives the most records in each window of compute units.}
            description {The probe makes at most N records in each window of UNITS compute units of the script.}
            example {
                set p [ztcl::probe add -proc g -rate {1 1000000}]
                f 1; f 2; f 3
                llength [ztcl::probe records -probe $p]
            } 1
            error {ztcl::probe add -proc f -rate x} {-rate needs a list of two numbers: records and compute units} {TCL VALUE}
        }
    }

    subcommand records {
        synopsis {ztcl::probe records ?-probe ID? ?-since SEQ? ?-where EXPR? ?-first N? ?-last N? ?-json?}
        summary {Gives the records that match, the oldest first.}
        description {
            Gives the records in order, the oldest first, as a list of dicts. A record has these fields:

            - `seq`: the sequence number of the record in the interpreter;
            - `units`: the compute units that the interpreter used before the record, the time of the record, the same in each run;
            - `thread`: the id of the thread of `thread::create`, or 0;
            - `probe` and `kind`: the id of the probe and its kind, `proc`, `line`, `command`, `variable`, or `error`;
            - `proc`: the words of the current call, as `info level 0` gives them, or an empty string at the global level;
            - the fields of the kind: `line`, `words`, `var`, `op`, `value`, `code`, `result`, `cmd`, `message`, `errorcode`, and `stack`;
            - `probe_error`: the error of the condition, when it failed;
            - `values`: the dict of the captured values.
        }
        returns {A list of dicts, or lines of JSON with `-json`.}
        see {{ztcl::probe add} {ztcl::probe clear}}
        example {
            set p [ztcl::probe add -proc g]
            g 7
            dict keys [lindex [ztcl::probe records -probe $p] 0]
        } {seq units thread probe kind proc words values}
        error {ztcl::probe records -probe nope} {bad probe id "nope"} {ZTCL PROBE ID}
        error {ztcl::probe records -bogus 1} {bad option "-bogus": must be -first, -json, -last, -probe, -since, or -where} {TCL LOOKUP INDEX option}
        error {ztcl::probe records -bogus} {bad option "-bogus": must be -first, -json, -last, -probe, -since, or -where} {TCL LOOKUP INDEX option}
        option -probe {
            value ID
            type {probe id}
            summary {Gives only the records of one probe.}
            description {Only the records of the probe ID. The records stay after `remove` of the probe.}
            example {
                set p [ztcl::probe add -proc g]
                g 1
                ztcl::probe remove $p
                llength [ztcl::probe records -probe $p]
            } 1
            error {ztcl::probe records -probe} {option "-probe" needs a value} {TCL VALUE}
        }
        option -since {
            value SEQ
            type integer
            summary {Gives only the records from a sequence number on.}
            description {Only the records with a sequence number of at least SEQ, to read only the new records.}
            example {
                set p [ztcl::probe add -proc g -capture n]
                g 1; g 2; g 3
                set s [dict get [lindex [ztcl::probe records -probe $p] 1] seq]
                lmap r [ztcl::probe records -probe $p -since $s] {dict get $r values n}
            } {2 3}
            error {ztcl::probe records -since x} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
        option -where {
            value EXPR
            type expression
            summary {Gives only the records where an expression is true.}
            description {A bare name in EXPR is a field of the record or a captured value, so `-where {n > 10}` works. A record with no such field does not match.}
            example {
                set p [ztcl::probe add -proc g -capture n]
                g 1; g 2; g 3; g 4
                list [lmap r [ztcl::probe records -probe $p -where {n > 2}] {dict get $r values n}] [ztcl::probe records -probe $p -where {nosuch > 1}]
            } {{3 4} {}}
            error {ztcl::probe records -where {x +}} "missing operand at _@_\nin expression \"\$x +_@_\"" {TCL PARSE EXPR MISSING}
        }
        option -first {
            value N
            type integer
            summary {Gives only the first N records that match.}
            description {Only the first N records that match the other options.}
            example {
                set p [ztcl::probe add -proc g -capture n]
                g 1; g 2; g 3
                lmap r [ztcl::probe records -probe $p -first 2] {dict get $r values n}
            } {1 2}
            error {ztcl::probe records -first x} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
        option -last {
            value N
            type integer
            summary {Gives only the last N records that match.}
            description {Only the last N records that match the other options.}
            example {
                set p [ztcl::probe add -proc g -capture n]
                g 1; g 2; g 3
                lmap r [ztcl::probe records -probe $p -last 1] {dict get $r values n}
            } 3
            error {ztcl::probe records -last x} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
        option -json {
            type flag
            summary {Gives one line of JSON for each record.}
            description {Gives the records as one string with one line of JSON for each record, each line with a newline at its end.}
            example {
                set p [ztcl::probe add -error]
                catch {error boom {} {MY CODE}}
                ztcl::probe remove $p
                set j [ztcl::probe records -probe $p -json]
                list [string equal [string index $j end] "\n"] [regsub {"seq":\d+,"units":\d+,"thread":0,"probe":"p\d+",} [string trim $j] {}]
            } {1 {{"kind":"error","proc":"","cmd":"error boom {} {MY CODE}","message":"boom","errorcode":"MY CODE","values":{}}}}
            noerrors {A flag has no value to check.}
        }
    }

    subcommand list {
        synopsis {ztcl::probe list}
        summary {Gives a dict for each probe.}
        description {Gives a list with a dict for each probe, with the keys `id`, `kind`, `target`, `line` for a line probe, `state` (`active` or `waiting`), `hits`, `records`, `dropped` (the hits that a limit did not record), and `errors` (the errors of the condition and the captures).}
        returns {A list of dicts.}
        see {{ztcl::probe add} {ztcl::probe remove}}
        example {
            ztcl::probe add -proc nosuch
            lindex [ztcl::probe list] end
        } {id p1 kind proc target nosuch state waiting hits 0 records 0 dropped 0 errors 0}
        example {
            set p [ztcl::probe add -var ::q]
            dict get [lindex [ztcl::probe list] end] target
        } ::q
        error {ztcl::probe list x} {wrong # args: should be "ztcl::probe list"} {TCL WRONGARGS}
    }

    subcommand remove {
        synopsis {ztcl::probe remove ID|all}
        summary {Removes a probe, or each probe.}
        description {Removes the probe ID, or each probe with `all`. The records stay. When the last probe of a proc goes, its body compiles again with no probe.}
        returns {An empty string.}
        see {{ztcl::probe add} {ztcl::probe clear}}
        example {
            set p [ztcl::probe add -proc g]
            ztcl::probe remove $p
            llength [ztcl::probe list]
        } 0
        example {
            ztcl::probe add -proc f
            ztcl::probe add -proc g
            ztcl::probe remove all
            ztcl::probe list
        } {}
        error {ztcl::probe remove p99} {no probe "p99"} {ZTCL PROBE ID}
        error {ztcl::probe remove nope} {bad probe id "nope"} {ZTCL PROBE ID}
        error {ztcl::probe remove} {wrong # args: should be "ztcl::probe remove id|all"} {TCL WRONGARGS}
    }

    subcommand clear {
        synopsis {ztcl::probe clear}
        summary {Removes each record.}
        description {Removes each record. The probes stay.}
        returns {An empty string.}
        see {{ztcl::probe records} {ztcl::probe remove}}
        example {
            ztcl::probe add -proc g
            g 1
            ztcl::probe clear
            list [ztcl::probe records] [llength [ztcl::probe list]]
        } {{} 1}
        error {ztcl::probe clear x} {wrong # args: should be "ztcl::probe clear"} {TCL WRONGARGS}
    }

    subcommand configure {
        synopsis {ztcl::probe configure ?-size N? ?-budget N? ?-maxlen N?}
        summary {Gives or sets the size of the ring, the budget of a hit, and the length of a value.}
        description {With no option it gives the dict of the settings. With options it sets them and gives an empty string.}
        returns {The dict of the settings, or an empty string.}
        see {{ztcl::probe records}}
        example {ztcl::probe configure} {-size 1000 -budget 100000 -maxlen 256}
        error {ztcl::probe configure -bogus 1} {bad option "-bogus": must be -budget, -maxlen, or -size} {TCL LOOKUP INDEX option}
        error {ztcl::probe configure -size} {wrong # args: should be "ztcl::probe configure ?-size n? ?-budget n? ?-maxlen n?"} {TCL WRONGARGS}
        option -size {
            value N
            type integer
            default 1,000
            summary {Gives the count of records that the ring keeps.}
            description {The ring keeps the last N records, 0 to 1,000,000. A smaller size drops the oldest records, and 0 keeps none.}
            example {
                set p [ztcl::probe add -proc g -capture n]
                g 1; g 2; g 3
                ztcl::probe configure -size 2
                lmap r [ztcl::probe records -probe $p] {dict get $r values n}
            } {2 3}
            error {ztcl::probe configure -size 2000000} {-size must be at most 1000000} {TCL VALUE}
            error {ztcl::probe configure -size -1} {-size must be 0 or more} {TCL VALUE}
        }
        option -budget {
            value N
            type integer
            default 100,000
            summary {Gives the compute units of one hit.}
            description {The most compute units of one hit, with its condition and its captures, 1 or more.}
            example {
                ztcl::probe configure -budget 500
                dict get [ztcl::probe configure] -budget
            } 500
            error {ztcl::probe configure -budget 0} {-budget must be 1 or more} {TCL VALUE}
            error {ztcl::probe configure -budget x} {expected integer but got "x"} {TCL VALUE NUMBER}
        }
        option -maxlen {
            value N
            type integer
            default 256
            summary {Gives the most bytes of a captured value.}
            description {A captured value or a local variable of `-locals` of more than N bytes keeps its first N bytes and gets the count of all its bytes, such as `aaaa... (40 bytes)`. N is 16 or more.}
            example {
                ztcl::probe configure -maxlen 16
                set p [ztcl::probe add -proc f -line 3 -capture x]
                f 40
                dict get [lindex [ztcl::probe records -probe $p] 0] values
            } {x {aaaaaaaaaaaaaaaa... (40 bytes)}}
            error {ztcl::probe configure -maxlen 4} {-maxlen must be 16 or more} {TCL VALUE}
        }
    }
}
