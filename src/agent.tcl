# The module ztcl::agent (ztcl#216): an LLM agent loop in an isolated
# thread that has only the data and the tools that the host gives it.
# docs/dev/agent-sandbox.md has the design and the threat model.
#
# A tool is a Tcl command. The host names its commands in -tools, and
# the schema of each one comes from the command: `info args` and
# `info default` of a proc, and the text and the types of
# `ztcl::agent doc`. In the thread, each host tool is a command of the
# same name. The loop of the thread is a coroutine: a call of a host
# tool yields an action to the host, and the host gives back the result
# or the error, with its -errorcode and errorInfo. So an error of a
# tool, a command that the thread does not have, and a capability that
# the thread does not have are each a Tcl error that the model gets as
# the result of its call.
#
# The host drives the loop. It asks the thread for each next action:
#
#   type model body JSON            post the body to the endpoint
#   type tool name N args LIST      run the host command N with LIST
#   type local name N args LIST ok B result T errorcode C
#                                   a tool of the thread ran (the log)
#   type done result D              the result, checked against -result
#   type error text T               the thread cannot go on
#
# The host never runs a script that the thread sends. The requests and
# the replies have the form of the Messages API (-api messages) or of
# the chat completions API (-api openai).
#
# SPDX-License-Identifier: BSD-2-Clause

package require ztcl::json

namespace eval ::ztcl::agent {
    namespace export run post check schema doc describe
    namespace ensemble create
    variable version 0.2
    variable docs {}

    # The procs of the tool schemas. They run in the host and, as a part
    # of `core`, in the thread.
    variable shared {
        # The JSON schema of a type of a tool argument or of a result.
        proc type_json {type} {
            switch -- [lindex $type 0] {
                string {return [ztcl::json object type [ztcl::json string string]]}
                int {return [ztcl::json object type [ztcl::json string integer]]}
                number {return [ztcl::json object type [ztcl::json string number]]}
                bool {return [ztcl::json object type [ztcl::json string boolean]]}
                enum {
                    set words {}
                    foreach w [lrange $type 1 end] {lappend words [ztcl::json string $w]}
                    return [ztcl::json object type [ztcl::json string string] enum [ztcl::json array {*}$words]]
                }
                list {return [ztcl::json object type [ztcl::json string array] items [type_json [lindex $type 1]]]}
                dict {return [schema [lindex $type 1]]}
            }
            return -code error -errorcode {ZTCL AGENT SCHEMA} "bad type \"$type\""
        }

        # The JSON schema of a list of keys and types: an object with
        # exactly these keys.
        proc schema {spec} {
            set props {}
            set req {}
            foreach {key type} $spec {
                lappend props $key [type_json $type]
                lappend req [ztcl::json string $key]
            }
            ztcl::json object type [ztcl::json string object] properties [ztcl::json object {*}$props] required [ztcl::json array {*}$req] additionalProperties [ztcl::json bool false]
        }

        # The spec of a command as a tool: {name text schema params}.
        # params is a list of {arg kind}, kind required, optional, or
        # rest (the `args` of a proc). A command that is not a proc has
        # its words as `args`.
        proc describe {name docs} {
            set text "The command $name."
            set types {}
            if {[dict exists $docs $name]} {
                set text [dict get $docs $name text]
                set types [dict get $docs $name types]
            }
            set props {}
            set req {}
            set params {}
            if {[info procs ::$name] ne ""} {
                foreach a [info args ::$name] {
                    set type [expr {[dict exists $types $a] ? [dict get $types $a] : "string"}]
                    if {$a eq "args"} {
                        lappend params [list args rest]
                        lappend props args [type_json [list list $type]]
                    } elseif {[info default ::$name $a d]} {
                        lappend params [list $a optional]
                        lappend props $a [type_json $type]
                    } else {
                        lappend params [list $a required]
                        lappend props $a [type_json $type]
                        lappend req [ztcl::json string $a]
                    }
                }
            } else {
                lappend params [list args rest]
                lappend props args [type_json {list string}]
            }
            set s [ztcl::json object type [ztcl::json string object] properties [ztcl::json object {*}$props] required [ztcl::json array {*}$req]]
            return [list $name $text $s $params]
        }

        # The words of a call of a tool, from the input dict of the model.
        proc words {params input} {
            set argv {}
            set skipped 0
            foreach p $params {
                lassign $p a kind
                if {![dict exists $input $a]} {
                    if {$kind eq "required"} {
                        return -code error -errorcode {TCL WRONGARGS} "the call has no argument \"$a\""
                    }
                    set skipped 1
                    continue
                }
                if {$skipped} {
                    return -code error -errorcode {TCL WRONGARGS} "the argument \"$a\" needs the arguments before it"
                }
                if {$kind eq "rest"} {lappend argv {*}[dict get $input $a]} else {lappend argv [dict get $input $a]}
            }
            dict for {k v} $input {
                if {[lsearch -index 0 -exact $params $k] < 0} {
                    return -code error -errorcode {TCL WRONGARGS} "the tool has no argument \"$k\""
                }
            }
            return $argv
        }
    }
    namespace eval shared $shared

    # The code of the thread. It runs with no capability.
    variable core {
        package require ztcl::json
        namespace eval ::agent {
            variable api messages
            variable messages {}
            variable system {}
            variable tools {}
            variable params {}
            variable host {}
            variable max_tokens 4096
            variable docs {}
        }

        # `doc NAME TEXT ?ARG TYPE ...?` for the tools of the thread.
        proc ::agent::doc {name text args} {
            dict set ::agent::docs $name [dict create text $text types $args]
        }

        # specs: a list of {name text schema params where}.
        proc ::agent::start {api system prompt data specs local max_tokens} {
            set ::agent::api $api
            set ::agent::system $system
            set ::agent::max_tokens $max_tokens
            foreach name $local {
                lappend specs [list {*}[::agent::shared::describe $name $::agent::docs] thread]
            }
            foreach spec $specs {
                lassign $spec name text schema params where
                dict set ::agent::params $name $params
                if {$api eq "openai"} {
                    lappend ::agent::tools [ztcl::json object type [ztcl::json string function] function [ztcl::json object name [ztcl::json string $name] description [ztcl::json string $text] parameters [ztcl::json raw $schema]]]
                } else {
                    lappend ::agent::tools [ztcl::json object name [ztcl::json string $name] description [ztcl::json string $text] input_schema [ztcl::json raw $schema]]
                }
                if {$where eq "host"} {
                    dict set ::agent::host $name 1
                    # The host tool is a command of the thread. A call
                    # yields to the host.
                    proc ::$name args [list ::agent::call $name]
                }
            }
            set text $prompt
            foreach {name value} $data {append text "\n\n<data name=\"$name\">\n$value\n</data>"}
            ::agent::user $text
            return {}
        }

        proc ::agent::call {name} {
            upvar 1 args argv
            set r [yield [list type tool name $name args $argv]]
            if {[dict get $r code] == 0} {return [dict get $r result]}
            return -code error -errorcode [dict get $r errorcode] -errorinfo [dict get $r errorinfo] [dict get $r result]
        }

        proc ::agent::user {text} {
            lappend ::agent::messages [ztcl::json object role [ztcl::json string user] content [ztcl::json string $text]]
        }

        proc ::agent::request {} {
            set parts [list max_tokens [ztcl::json number $::agent::max_tokens]]
            set msgs $::agent::messages
            if {$::agent::system ne ""} {
                if {$::agent::api eq "openai"} {
                    set msgs [linsert $msgs 0 [ztcl::json object role [ztcl::json string system] content [ztcl::json string $::agent::system]]]
                } else {
                    lappend parts system [ztcl::json string $::agent::system]
                }
            }
            lappend parts tools [ztcl::json array {*}$::agent::tools]
            lappend parts messages [ztcl::json array {*}$msgs]
            return [list type model body [ztcl::json object {*}$parts]]
        }

        proc ::agent::step {last} {
            if {[info commands ::agent::co] eq ""} {return [coroutine ::agent::co ::agent::loop]}
            return [::agent::co $last]
        }

        # The calls of a reply: a list of {id name input}, and the reply
        # goes on the list of messages.
        proc ::agent::calls {body} {
            set tree [lindex [ztcl::json parse -typed $body] 1]
            set out {}
            if {$::agent::api eq "openai"} {
                set msg [lindex [dict get [lindex [dict get $tree choices] 1 0 1] message] 1]
                set parts [list role [ztcl::json string assistant]]
                set text {}
                if {[dict exists $msg content] && [lindex [dict get $msg content] 0] eq "string"} {
                    set text [lindex [dict get $msg content] 1]
                }
                lappend parts content [ztcl::json string $text]
                if {[dict exists $msg tool_calls] && [lindex [dict get $msg tool_calls] 0] eq "array"} {
                    lappend parts tool_calls [ztcl::json encode -typed [dict get $msg tool_calls]]
                    foreach c [lindex [dict get $msg tool_calls] 1] {
                        set c [lindex $c 1]
                        set f [lindex [dict get $c function] 1]
                        set argtext [lindex [dict get $f arguments] 1]
                        if {[catch {ztcl::json parse -null {} $argtext} input]} {set input [list "" $argtext]}
                        if {$argtext eq ""} {set input {}}
                        lappend out [list [lindex [dict get $c id] 1] [lindex [dict get $f name] 1] $input]
                    }
                }
                lappend ::agent::messages [ztcl::json object {*}$parts]
            } else {
                set content [dict get $tree content]
                lappend ::agent::messages [ztcl::json object role [ztcl::json string assistant] content [ztcl::json encode -typed $content]]
                foreach b [ztcl::json get -null {} $body content] {
                    if {[dict get $b type] eq "tool_use"} {
                        lappend out [list [dict get $b id] [dict get $b name] [dict get $b input]]
                    }
                }
            }
            return $out
        }

        proc ::agent::result_msg {id ok text} {
            if {$::agent::api eq "openai"} {
                return [ztcl::json object role [ztcl::json string tool] tool_call_id [ztcl::json string $id] content [ztcl::json string $text]]
            }
            set parts [list type [ztcl::json string tool_result] tool_use_id [ztcl::json string $id] content [ztcl::json string $text]]
            if {!$ok} {lappend parts is_error [ztcl::json bool true]}
            return [ztcl::json object {*}$parts]
        }

        proc ::agent::loop {} {
            set nudged 0
            while 1 {
                set reply [yield [::agent::request]]
                if {[dict get $reply status] != 200} {
                    return [list type error text "the model endpoint gave status [dict get $reply status]"]
                }
                if {[catch {::agent::calls [dict get $reply body]} calls]} {
                    return [list type error text "the reply has a form that the agent does not read: $calls"]
                }
                if {[llength $calls] == 0} {
                    if {$nudged} {return [list type error text "the model gave no result"]}
                    set nudged 1
                    ::agent::user "Give your answer with the tool result."
                    continue
                }
                set results {}
                foreach c $calls {
                    lassign $c id name input
                    if {$name eq "result"} {return [list type done result $input]}
                    if {[dict exists $::agent::params $name]} {
                        set code [catch {
                            set argv [::agent::shared::words [dict get $::agent::params $name] $input]
                            ::$name {*}$argv
                        } res opts]
                    } else {
                        set argv {}
                        set code [catch {error "invalid command name \"$name\"" {} {TCL LOOKUP COMMAND}} res opts]
                    }
                    set ec [expr {$code == 1 ? [dict get $opts -errorcode] : ""}]
                    if {![dict exists $::agent::host $name]} {
                        yield [list type local name $name args $argv ok [expr {$code == 0}] result $res errorcode $ec]
                    }
                    if {$code == 1} {
                        set text "error: $res\nerrorcode: $ec\n[dict get $opts -errorinfo]"
                    } else {
                        set text $res
                    }
                    lappend results [::agent::result_msg $id [expr {$code == 0}] $text]
                }
                if {$::agent::api eq "openai"} {
                    lappend ::agent::messages {*}$results
                } else {
                    lappend ::agent::messages [ztcl::json object role [ztcl::json string user] content [ztcl::json array {*}$results]]
                }
            }
        }
    }
    append core "\nnamespace eval ::agent::shared [list $shared]\n"
}

# `ztcl::agent doc NAME TEXT ?ARG TYPE ...?`: the text of the host tool
# NAME and the types of its arguments, for its schema.
proc ::ztcl::agent::doc {args} {
    if {[llength $args] < 2} {
        return -code error -errorcode {TCL WRONGARGS} "wrong # args: should be \"ztcl::agent doc name text ?arg type ...?\""
    }
    set types [lassign $args name text]
    variable docs
    if {[info commands ::$name] eq ""} {
        return -code error -errorcode {ZTCL AGENT USAGE} "no command \"$name\" for a tool"
    }
    if {[llength $types] % 2} {
        return -code error -errorcode {ZTCL AGENT USAGE} "the argument \"[lindex $types end]\" has no type"
    }
    set known [expr {[info procs ::$name] ne "" ? [info args ::$name] : {args}}]
    foreach {a type} $types {
        if {$a ni $known} {
            return -code error -errorcode {ZTCL AGENT USAGE} "$name has no argument \"$a\": must be [::ztcl::agent::words_or $known]"
        }
        # The same check as the schema: an error here names the type.
        ::ztcl::agent::shared::type_json $type
    }
    dict set docs $name [dict create text $text types $types]
    return $name
}

# The words of a list for a message: "a", "a or b", or "a, b, or c".
proc ::ztcl::agent::words_or {words} {
    switch [llength $words] {
        0 {return ""}
        1 {return [lindex $words 0]}
        2 {return "[lindex $words 0] or [lindex $words 1]"}
    }
    return "[join [lrange $words 0 end-1] {, }], or [lindex $words end]"
}

# A wrong count of arguments with the name of the ensemble.
proc ::ztcl::agent::usage {text} {
    return -code error -level 2 -errorcode {TCL WRONGARGS} "wrong # args: should be \"ztcl::agent $text\""
}

# The spec of a host command as a tool: {name text schema params}.
proc ::ztcl::agent::describe {args} {
    if {[llength $args] != 1} {::ztcl::agent::usage "describe name"}
    lassign $args name
    variable docs
    if {[info commands ::$name] eq ""} {
        return -code error -errorcode {ZTCL AGENT USAGE} "no command \"$name\" for a tool"
    }
    ::ztcl::agent::shared::describe $name $docs
}

proc ::ztcl::agent::schema {args} {
    if {[llength $args] != 1} {::ztcl::agent::usage "schema spec"}
    ::ztcl::agent::shared::schema [lindex $args 0]
}

# Checks a value against a result schema. Gives the value, or an error
# with the code ZTCL AGENT RESULT.
proc ::ztcl::agent::check {args} {
    if {[llength $args] != 2} {::ztcl::agent::usage "check spec value"}
    ::ztcl::agent::check_dict {*}$args result
}

proc ::ztcl::agent::check_dict {spec value path} {
    if {[catch {dict size $value}]} {
        return -code error -errorcode {ZTCL AGENT RESULT} "$path is not a dict"
    }
    dict for {key type} $spec {
        if {![dict exists $value $key]} {
            return -code error -errorcode {ZTCL AGENT RESULT} "$path has no key \"$key\""
        }
        ::ztcl::agent::check_type $type [dict get $value $key] "$path.$key"
    }
    dict for {key v} $value {
        if {![dict exists $spec $key]} {
            return -code error -errorcode {ZTCL AGENT RESULT} "$path has the extra key \"$key\""
        }
    }
    return $value
}

proc ::ztcl::agent::check_type {type v path} {
    set bad [list return -code error -errorcode {ZTCL AGENT RESULT} "$path is not $type"]
    switch -- [lindex $type 0] {
        string {}
        int {if {![string is entier -strict $v]} {uplevel 0 $bad}}
        number {if {![string is double -strict $v]} {uplevel 0 $bad}}
        bool {if {![string is boolean -strict $v]} {uplevel 0 $bad}}
        enum {if {$v ni [lrange $type 1 end]} {uplevel 0 $bad}}
        list {
            if {[catch {llength $v}]} {uplevel 0 $bad}
            set i 0
            foreach e $v {::ztcl::agent::check_type [lindex $type 1] $e "$path.$i"; incr i}
        }
        dict {::ztcl::agent::check_dict [lindex $type 1] $v $path}
        default {return -code error -errorcode {ZTCL AGENT SCHEMA} "bad type \"$type\""}
    }
}

# One HTTP/1.1 POST. Gives {status N body TEXT}. An https URL needs the
# module ztcl::tls.
proc ::ztcl::agent::post {args} {
    if {[llength $args] != 3} {::ztcl::agent::usage "post url headers body"}
    lassign $args url headers body
    if {[catch {llength $headers} n] || $n % 2} {
        return -code error -errorcode {ZTCL AGENT HEADER} "the headers need a list of names and values"
    }
    if {![regexp {^(https?)://([^/:]+)(?::([0-9]+))?(/.*)?$} $url -> scheme host port path]} {
        return -code error -errorcode {ZTCL AGENT ENDPOINT} "bad endpoint \"$url\""
    }
    if {$path eq ""} {set path /}
    if {$scheme eq "https"} {
        if {$port eq ""} {set port 443}
        if {[catch {package require ztcl::tls}]} {
            return -code error -errorcode {ZTCL AGENT ENDPOINT} "an https endpoint needs the module ztcl::tls"
        }
        set s [ztcl::tls socket -servername $host $host $port]
    } else {
        if {$port eq ""} {set port 80}
        set s [socket $host $port]
    }
    try {
        fconfigure $s -translation binary
        set data [encoding convertto utf-8 $body]
        set req "POST $path HTTP/1.1\r\nHost: $host\r\nContent-Type: application/json\r\nContent-Length: [string length $data]\r\nConnection: close\r\n"
        foreach {k v} $headers {
            if {[regexp {[\r\n]} "$k$v"]} {
                return -code error -errorcode {ZTCL AGENT HEADER} "a header has a line end"
            }
            append req "$k: $v\r\n"
        }
        puts -nonewline $s "$req\r\n$data"
        flush $s
        if {![regexp {^HTTP/1\.[01] ([0-9]{3})} [gets $s] -> status]} {
            return -code error -errorcode {ZTCL AGENT HTTP} "the endpoint gave no HTTP status line"
        }
        set length -1
        set chunked 0
        while {[gets $s line] > 0} {
            set line [string trimright $line \r]
            if {$line eq ""} break
            if {[regexp -nocase {^content-length:\s*([0-9]+)} $line -> n]} {set length $n}
            if {[regexp -nocase {^transfer-encoding:\s*chunked} $line]} {set chunked 1}
        }
        if {$chunked} {
            set out {}
            while {1} {
                set size [expr 0x[string trim [gets $s]]]
                if {$size == 0} break
                append out [read $s $size]
                gets $s
            }
        } elseif {$length >= 0} {
            set out [read $s $length]
        } else {
            set out [read $s]
        }
        return [list status $status body [encoding convertfrom utf-8 $out]]
    } finally {
        close $s
    }
}

# Runs an agent. docs/modules/agent.md has the options.
proc ::ztcl::agent::run {args} {
    set o [dict create -isolation process -api messages -endpoint {} -header {} -model {} \
        -system {} -prompt {} -data {} -tools {} -local {} -setup {} -result {answer string} \
        -compute {} -meter {} -turns 8 -calls 16 -tokens 100000 -max-tokens 4096 -log {}]
    if {[llength $args] % 2} {
        return -code error -errorcode {ZTCL AGENT USAGE} "wrong # args: should be \"ztcl::agent run ?-option value ...?\""
    }
    foreach {k v} $args {
        if {![dict exists $o $k]} {
            return -code error -errorcode {ZTCL AGENT USAGE} "bad option \"$k\": must be [::ztcl::agent::words_or [lsort [dict keys $o]]]"
        }
        dict set o $k $v
    }
    if {[dict get $o -endpoint] eq ""} {
        return -code error -errorcode {ZTCL AGENT USAGE} "ztcl::agent run needs -endpoint"
    }
    foreach k {-turns -calls -tokens -max-tokens -compute} {
        set v [dict get $o $k]
        if {($k ne "-compute" || $v ne "") && ![string is entier -strict $v]} {
            return -code error -errorcode {TCL VALUE NUMBER} "expected integer but got \"$v\""
        }
    }
    if {[dict get $o -isolation] ni {interp process vm}} {
        return -code error -errorcode {ZTCL AGENT USAGE} "bad isolation level \"[dict get $o -isolation]\": must be interp, process, or vm"
    }
    if {[catch {llength [dict get $o -data]} n] || $n % 2} {
        return -code error -errorcode {ZTCL AGENT USAGE} "-data needs a list of names and values"
    }
    if {[catch {llength [dict get $o -header]} n] || $n % 2} {
        return -code error -errorcode {ZTCL AGENT HEADER} "the headers need a list of names and values"
    }
    if {[dict get $o -meter] ne "" && [info commands ::ztcl::meter] eq ""} {
        return -code error -errorcode {ZTCL AGENT USAGE} "-meter needs the capability meter"
    }
    if {[dict get $o -api] ni {messages openai}} {
        return -code error -errorcode {ZTCL AGENT USAGE} "bad api \"[dict get $o -api]\": must be messages or openai"
    }
    set result_spec [dict get $o -result]
    set specs {}
    foreach name [concat [dict get $o -tools] [dict get $o -local]] {
        if {$name eq "result"} {
            return -code error -errorcode {ZTCL AGENT USAGE} "the tool name \"result\" is for the result"
        }
    }
    foreach name [dict get $o -tools] {
        lappend specs [list {*}[::ztcl::agent::describe $name] host]
    }
    lappend specs [list result "Give the final answer." [::ztcl::agent::schema $result_spec] {} result]

    set create [list thread::create -joinable -isolation [dict get $o -isolation] -caps {}]
    if {[dict get $o -compute] ne ""} {lappend create -compute [dict get $o -compute]}
    if {[dict get $o -meter] ne ""} {lappend create -meter [dict get $o -meter]}
    set t [{*}$create]
    set log {}
    set turns 0
    set calls 0
    set tokens_in 0
    set tokens_out 0
    set note [list apply {{log e} {if {$log ne ""} {{*}$log $e}}} [dict get $o -log]]
    try {
        variable core
        thread::send $t $core
        if {[dict get $o -setup] ne ""} {thread::send $t [dict get $o -setup]}
        thread::send $t [list ::agent::start [dict get $o -api] [dict get $o -system] [dict get $o -prompt] \
            [dict get $o -data] $specs [dict get $o -local] [dict get $o -max-tokens]]
        set last {}
        while 1 {
            set a [thread::send $t [list ::agent::step $last]]
            if {[catch {dict get $a type} type]} {
                return -code error -errorcode {ZTCL AGENT PROTOCOL} "the thread gave no action"
            }
            switch -- $type {
                model {
                    if {[incr turns] > [dict get $o -turns]} {
                        return -code error -errorcode {ZTCL AGENT LIMIT turns} "the agent used its [dict get $o -turns] model calls"
                    }
                    set body [dict get $a body]
                    if {![ztcl::json valid $body] || [string index $body 0] ne "\{"} {
                        return -code error -errorcode {ZTCL AGENT PROTOCOL} "the thread gave a request that is not a JSON object"
                    }
                    if {[dict get $o -model] ne ""} {
                        set body "\{\"model\":[ztcl::json string [dict get $o -model]],[string range $body 1 end]"
                    }
                    set r [::ztcl::agent::post [dict get $o -endpoint] [dict get $o -header] $body]
                    set rb [dict get $r body]
                    set in 0
                    set out 0
                    if {[ztcl::json valid $rb]} {
                        foreach {k var} {input_tokens in prompt_tokens in output_tokens out completion_tokens out} {
                            catch {set $var [ztcl::json get $rb usage $k]}
                        }
                    }
                    incr tokens_in $in
                    incr tokens_out $out
                    set e [list kind model turn $turns status [dict get $r status] input_tokens $in output_tokens $out]
                    lappend log $e
                    {*}$note $e
                    if {$tokens_in + $tokens_out > [dict get $o -tokens]} {
                        return -code error -errorcode {ZTCL AGENT LIMIT tokens} "the agent used more than [dict get $o -tokens] tokens"
                    }
                    set last [list status [dict get $r status] body $rb]
                }
                tool - local {
                    if {[incr calls] > [dict get $o -calls]} {
                        return -code error -errorcode {ZTCL AGENT LIMIT calls} "the agent used its [dict get $o -calls] tool calls"
                    }
                    set name [dict get $a name]
                    set argv [dict get $a args]
                    if {$type eq "local"} {
                        set e [list kind tool where thread name $name args $argv ok [dict get $a ok] result [dict get $a result] errorcode [dict get $a errorcode]]
                        set last {}
                    } elseif {$name ni [dict get $o -tools]} {
                        return -code error -errorcode {ZTCL AGENT PROTOCOL} "the thread called \"$name\": it is not a host tool"
                    } else {
                        set code [catch {uplevel #0 [list $name {*}$argv]} res ropts]
                        set ec [expr {$code == 1 ? [dict get $ropts -errorcode] : ""}]
                        set ei [expr {$code == 1 ? [dict get $ropts -errorinfo] : ""}]
                        set e [list kind tool where host name $name args $argv ok [expr {$code == 0}] result $res errorcode $ec]
                        set last [list code [expr {$code == 1}] result $res errorcode $ec errorinfo $ei]
                    }
                    lappend log $e
                    {*}$note $e
                }
                done {
                    set res [dict get $a result]
                    if {[catch {::ztcl::agent::check_dict $result_spec $res result} msg]} {
                        set e [list kind result ok 0 error $msg]
                        lappend log $e
                        {*}$note $e
                        return -code error -errorcode {ZTCL AGENT RESULT} $msg
                    }
                    set e [list kind result ok 1]
                    lappend log $e
                    {*}$note $e
                    return [dict create result $res log $log turns $turns calls $calls input_tokens $tokens_in output_tokens $tokens_out]
                }
                error {
                    return -code error -errorcode {ZTCL AGENT MODEL} [dict get $a text]
                }
                default {
                    return -code error -errorcode {ZTCL AGENT PROTOCOL} "unknown action \"$type\""
                }
            }
        }
    } on error {msg opts} {
        # The end of the compute limit or of the memory of the thread.
        if {[lindex [dict get $opts -errorcode] 0] eq "THREAD" || ![thread::exists $t]} {
            dict set opts -errorcode {ZTCL AGENT LIMIT thread}
            return -options $opts "the agent thread ended: $msg"
        }
        return -options $opts $msg
    } finally {
        # Each send waits for its answer, so the thread waits for a
        # message here, and the join is short. After the join the meter
        # has the counts of the thread.
        catch {thread::release $t}
        catch {thread::join $t}
    }
}

package provide ztcl::agent $::ztcl::agent::version
