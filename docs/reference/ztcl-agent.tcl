# The command reference: ztcl::agent. The format is in
# docs/dev/reference-format.md.

command ztcl::agent {
    area ztcl
    since 1.0.0-beta.1
    capability thread
    flags {--allow thread,socket,channels,event,meter}
    setup {
        package require ztcl::agent
        # A fake model on 127.0.0.1, on a port of the system, in a thread: each
        # request gets the next reply of ::replies, and ::requests keeps them.
        set srv [thread::create {
            proc serve {c a p} {
                fconfigure $c -translation binary
                set len 0
                set hs {}
                while {[gets $c line] >= 0 && [set line [string trim $line]] ne ""} {
                    lappend hs $line
                    regexp -nocase {^content-length: *(\d+)} $line -> len
                }
                lappend ::requests [list $hs [read $c $len]]
                set body [lindex $::replies 0]
                set ::replies [lrange $::replies 1 end]
                puts -nonewline $c "HTTP/1.1 $::status OK\r\nContent-Length: [string length $body]\r\nConnection: close\r\n\r\n$body"
                close $c
            }
            set ::status 200
            set ::replies {}
            set ::requests {}
            set ::port [lindex [fconfigure [socket -server serve -myaddr 127.0.0.1 0] -sockname] 2]
            thread::wait
        }]
        set url http://127.0.0.1:[thread::send $srv {set ::port}]/v1/messages
        # Sets the replies of the fake model, and gives the requests that it got.
        proc replies {args} { thread::send $::srv [list set ::replies $args] }
        proc requests {} { thread::send $::srv {set ::requests} }
        # A reply of the Messages API with one call of a tool.
        proc call {name input} { return "{\"content\":\[{\"type\":\"tool_use\",\"id\":\"t[incr ::id]\",\"name\":\"$name\",\"input\":$input}\],\"usage\":{\"input_tokens\":5,\"output_tokens\":3}}" }
        proc add {a b} { expr {$a + $b} }
    }
    synopsis {ztcl::agent SUBCOMMAND ?ARG ...?}
    summary {Runs an LLM agent loop in an isolated thread that has only the data and the tools that the host gives it.}
    description {
        The commands of a sandboxed agent. `run` runs the loop of a model in a thread with no capability: the host posts each request to its one endpoint with its own headers, runs only the tools that it names, and checks the result against a schema. [Sandboxed agents](agents/) is the guide, with a recorded run.

        Load the module with `package require ztcl::agent`. It needs `ztcl::json` in the build, and the capability `thread` in the host. The host posts to the endpoint, so it also needs `socket` and `channels`, and its network policy must allow the endpoint; an `https` endpoint needs the module `ztcl::tls`.

        A result schema is a list of keys and types. A type is `string`, `int`, `number`, or `bool`; `{enum WORD ...}`, one of the words; `{list TYPE}`, a list of values of TYPE; or `{dict SCHEMA}`, a dict with the keys of SCHEMA. A dict has exactly the keys of its schema.

        An error of the module has a code that starts with `ZTCL AGENT`: `USAGE`, `ENDPOINT`, `HTTP`, `HEADER`, `MODEL`, `LIMIT turns`, `LIMIT calls`, `LIMIT tokens`, `LIMIT thread`, `RESULT`, `PROTOCOL`, and `SCHEMA`. A subcommand has no short form, and the message of a wrong count of arguments names the proc of the module, such as `::ztcl::agent::post` ([issue 741](https://github.com/beetlebugorg/ztcl/issues/741)).

        The examples of this page run with `--allow thread,socket,channels,event,meter`. The setup starts a fake model on 127.0.0.1 in a thread, which gives the replies that `replies` sets, and makes the procs `call`, which writes a reply with one call of a tool, `requests`, and the tool `add`.
    }
    returns {The result of the subcommand.}
    page modules/agent/
    see {ztcl::json thread::create ztcl::meter}
    example {
        replies [call result {{"answer":"hi"}}]
        dict get [ztcl::agent run -endpoint $url -isolation interp -prompt hi] result
    } {answer hi}
    example {ztcl::agent check {n int tags {list string}} {n 3 tags {a b}}} {n 3 tags {a b}}
    error {ztcl::agent bogus} {unknown or ambiguous subcommand "bogus": must be check, describe, doc, post, run, or schema} {TCL LOOKUP SUBCOMMAND bogus}
    error {ztcl::agent} {wrong # args: should be "ztcl::agent subcommand ?arg ...?"} {TCL WRONGARGS}

    subcommand run {
        synopsis {ztcl::agent run ?-option value ...?}
        summary {Runs the loop of the model and gives a dict of the result, the log, and the counts.}
        description {
            Starts a thread with `thread::create -caps {}`, with no file, socket, program, clock, or thread command, and runs the loop: the host posts a request to the endpoint, and each call of a tool in the reply runs a tool, until the model calls the tool `result`. A reply with no call of a tool gets one more user message that asks for the result tool, and a second such reply is the error `ZTCL AGENT MODEL`. A status other than 200 is also `ZTCL AGENT MODEL`.

            The result is a dict: `result`, the checked result; `log`, a list of dicts, one for each model call, tool call, and the result; `turns`; `calls`; `input_tokens`; and `output_tokens`. An entry of the log has `kind`: `model` with `turn`, `status`, `input_tokens`, and `output_tokens`; `tool` with `where` (`host` or `thread`), `name`, `args`, `ok`, `result`, and `errorcode`; and `result` with `ok`, and `error` when the result does not match the schema. The model gets each error of a tool as the result of its call, with the error code and `errorInfo`.
        }
        returns {A dict.}
        see {{ztcl::agent post} {ztcl::agent check}}
        example {
            replies [call result {{"answer":"hi"}}]
            set r [ztcl::agent run -endpoint $url -isolation interp]
            list [dict keys $r] [dict get $r log]
        } {{result log turns calls input_tokens output_tokens} {{kind model turn 1 status 200 input_tokens 5 output_tokens 3} {kind result ok 1}}}
        example {
            replies [call nosuch {{}}] [call result {{"answer":"x"}}]
            lindex [dict get [ztcl::agent run -endpoint $url -isolation interp] log] 1
        } {kind tool where thread name nosuch args {} ok 0 result {invalid command name "nosuch"} errorcode {TCL LOOKUP COMMAND}}
        error {ztcl::agent run -endpoint $url -bogus 1} {bad option "-bogus": must be -api, -calls, -compute, -data, -endpoint, -header, -isolation, -local, -log, -max-tokens, -meter, -model, -prompt, -result, -setup, -system, -tokens, -tools, -turns} {ZTCL AGENT USAGE}
        error {
            thread::send $srv {set ::status 500}
            ztcl::agent run -endpoint $url -isolation interp
        } {the model endpoint gave status 500} {ZTCL AGENT MODEL}
        error {
            thread::send $srv {set ::status 200}
            set text {{"content":[{"type":"text","text":"no"}],"usage":{"input_tokens":1,"output_tokens":1}}}
            replies $text $text
            ztcl::agent run -endpoint $url -isolation interp
        } {the model gave no result} {ZTCL AGENT MODEL}
        option -endpoint {
            value URL
            type URL
            summary {Gives the one URL of the model.}
            description {An `http://` or `https://` URL. It is needed.}
            example {
                replies [call result {{"answer":"hi"}}]
                ztcl::agent run -endpoint $url -isolation interp
                lindex [requests] end 0 0
            } {POST /v1/messages HTTP/1.1}
            error {ztcl::agent run -prompt hi} {ztcl::agent run needs -endpoint} {ZTCL AGENT USAGE}
            error {ztcl::agent run -endpoint ftp://x -isolation interp} {bad endpoint "ftp://x"} {ZTCL AGENT ENDPOINT}
        }
        option -header {
            value LIST
            type {list of names and values}
            summary {Gives the headers of the host, such as the key.}
            description {The headers that the host adds to each request. The thread never gets them.}
            example {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -header {x-api-key K1}
                lsearch -inline [lindex [requests] end 0] x-api-key*
            } {x-api-key: K1}
            error {ztcl::agent run -endpoint $url -isolation interp -header {a "b\nc"}} {a header has a line end} {ZTCL AGENT HEADER}
        }
        option -model {
            value NAME
            type string
            summary {Gives the model field of each request.}
            description {The host puts NAME in the field `model` of each request.}
            example {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -model m1
                string match {*"model":"m1"*} [lindex [requests] end 1]
            } 1
            noerrors {Each name is valid.}
        }
        option -system {
            value TEXT
            type string
            summary {Gives the system text.}
            description {The field `system` of each request.}
            example {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -system S1
                string match {*"system":"S1"*} [lindex [requests] end 1]
            } 1
            noerrors {Each text is valid.}
        }
        option -prompt {
            value TEXT
            type string
            summary {Gives the first user text.}
            description {The text of the first user message.}
            example {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -prompt hi
                expr {[string first {"messages":[{"role":"user","content":"hi"}]} [lindex [requests] end 1]] >= 0}
            } 1
            noerrors {Each text is valid.}
        }
        option -data {
            value LIST
            type {list of names and values}
            summary {Gives data for the first user message.}
            description {Each value goes in the first user message as `<data name="NAME">`, after the prompt. An odd list gives no data block and no error (issue 741).}
            example {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -data {email hello}
                string match {*<data name=\\"email\\">\\nhello\\n</data>*} [lindex [requests] end 1]
            } 1
            noerrors {The list is not checked (issue 741).}
        }
        option -tools {
            value LIST
            type {list of command names}
            summary {Gives the host commands that the model can call.}
            description {The thread gets a command of each name, and a call runs the command of the host at the global level with the words from the input of the model. The spec of each tool is the one of `describe`. A tool cannot have the name `result`.}
            example {
                replies [call add {{"a":"2","b":"3"}}] [call result {{"answer":"5"}}]
                set r [ztcl::agent run -endpoint $url -isolation interp -tools add]
                list [dict get $r result] [lindex [dict get $r log] 1]
            } {{answer 5} {kind tool where host name add args {2 3} ok 1 result 5 errorcode {}}}
            example {
                replies [call add {{"a":"x","b":"1"}}] [call result {{"answer":"e"}}]
                dict get [lindex [dict get [ztcl::agent run -endpoint $url -isolation interp -tools add] log] 1] errorcode
            } {ARITH DOMAIN {non-numeric string}}
            error {ztcl::agent run -endpoint $url -tools nosuch} {no command "nosuch" for a tool} {ZTCL AGENT USAGE}
            error {
                proc result {} {}
                ztcl::agent run -endpoint $url -tools result
            } {the tool name "result" is for the result} {ZTCL AGENT USAGE}
        }
        option -local {
            value LIST
            type {list of command names}
            summary {Gives the commands of the thread that the model can call.}
            description {The names of commands of the thread, made by `-setup`.}
            example {
                replies [call twice {{"n":"4"}}] [call result {{"answer":"8"}}]
                set r [ztcl::agent run -endpoint $url -isolation interp -setup {proc twice {n} {expr {$n * 2}}} -local twice]
                list [dict get $r result] [lindex [dict get $r log] 1]
            } {{answer 8} {kind tool where thread name twice args 4 ok 1 result 8 errorcode {}}}
            noerrors {A name with no command of the thread is a call that fails, in the log.}
        }
        option -setup {
            value SCRIPT
            type script
            summary {Gives a script that runs in the thread before the loop.}
            description {The script can use `::agent::doc` in place of `ztcl::agent doc`. It runs with the limits of the thread.}
            example {
                replies [call twice {{"n":"1"}}] [call result {{"answer":"2"}}]
                dict get [ztcl::agent run -endpoint $url -isolation interp -setup {proc twice {n} {expr {$n * 2}}} -local twice] result
            } {answer 2}
            error {ztcl::agent run -endpoint $url -isolation interp -setup {while 1 {}} -compute 1000} {the agent thread ended: compute limit reached} {ZTCL AGENT LIMIT thread}
        }
        option -api {
            value FORM
            type {messages or openai}
            default messages
            values {messages openai}
            summary {Gives the form of the requests.}
            description {`messages` is the Messages API: `messages` with `tool_use` and `tool_result` blocks, `tools` with `input_schema`, and the counts `usage.input_tokens` and `usage.output_tokens`. `openai` is chat completions, as llama-server serves it: `messages` with `tool_calls` and `tool` messages, `tools` of type `function`, and the counts `usage.prompt_tokens` and `usage.completion_tokens`.}
            example {
                replies {{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"result","arguments":"{\"answer\":\"ok\"}"}}]}}],"usage":{"prompt_tokens":7,"completion_tokens":2}}}
                set r [ztcl::agent run -endpoint $url -isolation interp -api openai]
                list [dict get $r result] [dict get $r input_tokens] [dict get $r output_tokens]
            } {{answer ok} 7 2}
            error {ztcl::agent run -endpoint $url -api bogus} {bad api "bogus": must be messages or openai} {ZTCL AGENT USAGE}
        }
        option -result {
            value SCHEMA
            type {result schema}
            default {answer string}
            summary {Gives the schema of the result.}
            description {The model gives its result with the tool `result`, whose input schema is `ztcl::agent schema SCHEMA`, and `run` checks it as `check` does.}
            example {
                replies [call result {{"n":3,"tags":["a"]}}]
                dict get [ztcl::agent run -endpoint $url -isolation interp -result {n int tags {list string}}] result
            } {n 3 tags a}
            error {ztcl::agent run -endpoint $url -isolation interp -result {n bogus}} {bad type "bogus"} {ZTCL AGENT SCHEMA}
            error {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -result {n int}
            } {result has no key "n"} {ZTCL AGENT RESULT}
        }
        option -isolation {
            value LEVEL
            type {process or interp}
            default process
            values {process interp}
            summary {Gives the isolation level of the thread.}
            description {The level of `thread::create -isolation`: `process` runs the thread in a child process, and `interp` in an interpreter of this process.}
            example {
                replies [call result {{"answer":"x"}}]
                dict get [ztcl::agent run -endpoint $url -isolation interp] result
            } {answer x}
            error {ztcl::agent run -endpoint $url -isolation bogus} {bad isolation level "bogus": must be interp, process, or vm} NONE
        }
        option -compute {
            value UNITS
            type integer
            default {the limit of the thread group}
            summary {Gives the compute limit of the thread.}
            description {The thread ends at UNITS compute units, and `run` gives `ZTCL AGENT LIMIT thread`. The thread also ends at its memory limit or at a crash of its child process.}
            example {
                replies [call result {{"answer":"x"}}]
                dict get [ztcl::agent run -endpoint $url -isolation interp -compute 1000000] result
            } {answer x}
            error {ztcl::agent run -endpoint $url -isolation interp -setup {while 1 {}} -compute 1000} {the agent thread ended: compute limit reached} {ZTCL AGENT LIMIT thread}
        }
        option -meter {
            value NAME
            type {meter name}
            summary {Counts the thread in a meter.}
            description {The thread counts in the meter NAME of `ztcl::meter`, which needs the capability `meter`. With no capability `meter` the error is the one of `thread::create` (issue 741).}
            example {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -meter m
                expr {[dict get [ztcl::meter get m] units] > 0}
            } 1
            noerrors {A new name makes the meter.}
        }
        option -turns {
            value N
            type integer
            default 8
            summary {Gives the most model calls.}
            description {At the end of N model calls with no result, `run` gives `ZTCL AGENT LIMIT turns`. N is not checked before the first request (issue 741).}
            example {
                replies [call add {{"a":"1","b":"1"}}] [call add {{"a":"1","b":"1"}}]
                catch {ztcl::agent run -endpoint $url -isolation interp -tools add -turns 1} msg
                set msg
            } {the agent used its 1 model calls}
            error {
                replies [call add {{"a":"1","b":"1"}}]
                ztcl::agent run -endpoint $url -isolation interp -tools add -turns 1
            } {the agent used its 1 model calls} {ZTCL AGENT LIMIT turns}
        }
        option -calls {
            value N
            type integer
            default 16
            summary {Gives the most tool calls, of the host and of the thread.}
            description {At the call after N tool calls, `run` gives `ZTCL AGENT LIMIT calls`.}
            example {
                replies [call add {{"a":"1","b":"1"}}] [call result {{"answer":"2"}}]
                dict get [ztcl::agent run -endpoint $url -isolation interp -tools add -calls 1] calls
            } 1
            error {
                replies [call add {{"a":"1","b":"1"}}] [call add {{"a":"1","b":"1"}}] [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -tools add -calls 1
            } {the agent used its 1 tool calls} {ZTCL AGENT LIMIT calls}
        }
        option -tokens {
            value N
            type integer
            default 100,000
            summary {Gives the most tokens of the replies.}
            description {The most of the sum of `usage.input_tokens` and `usage.output_tokens` of the replies. Past it, `run` gives `ZTCL AGENT LIMIT tokens`.}
            example {
                replies [call result {{"answer":"x"}}]
                dict get [ztcl::agent run -endpoint $url -isolation interp -tokens 8] input_tokens
            } 5
            error {
                replies [call add {{"a":"1","b":"1"}}] [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -tools add -tokens 5
            } {the agent used more than 5 tokens} {ZTCL AGENT LIMIT tokens}
        }
        option -max-tokens {
            value N
            type integer
            default 4,096
            summary {Gives the max_tokens field of each request.}
            description {The host puts N in the field `max_tokens` of each request.}
            example {
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -max-tokens 50
                string match {*"max_tokens":50,*} [lindex [requests] end 1]
            } 1
            noerrors {The value goes to the endpoint as it is.}
        }
        option -log {
            value CMD
            type {command prefix}
            summary {Gives a command that gets each entry of the log at once.}
            description {`run` calls CMD with each entry of the log as it comes, before the end of the run.}
            example {
                set ::L {}
                replies [call result {{"answer":"x"}}]
                ztcl::agent run -endpoint $url -isolation interp -log {lappend ::L}
                set ::L
            } {{kind model turn 1 status 200 input_tokens 5 output_tokens 3} {kind result ok 1}}
            noerrors {An error of CMD is not checked here.}
        }
    }

    subcommand doc {
        synopsis {ztcl::agent doc NAME TEXT ?ARG TYPE ...?}
        summary {Sets the text of a tool and the types of its arguments.}
        description {Sets the text of the tool NAME and the types of its arguments, for its schema, and gives NAME. An argument with no type is a `string`. `doc` checks no type and no name: a bad type gives its error at `describe` or `run` (issue 741).}
        returns {NAME.}
        see {{ztcl::agent describe}}
        argument NAME {
            type {command name}
            summary {The name of the tool.}
        }
        argument TEXT {
            type string
            summary {The text of the tool for the model.}
        }
        example {
            proc greet {name {times 1}} {}
            ztcl::agent doc greet "Greets a person." name string times int
        } greet
        example {
            proc greet {name {times 1}} {}
            ztcl::agent doc greet "Greets a person." times int
            lrange [ztcl::agent describe greet] 0 1
        } {greet {Greets a person.}}
        error {ztcl::agent doc greet} {wrong # args: should be "::ztcl::agent::doc name text ?arg ...?"} {TCL WRONGARGS}
    }

    subcommand describe {
        synopsis {ztcl::agent describe NAME}
        summary {Gives the spec of a command as a tool.}
        description {Gives the list `NAME TEXT SCHEMA PARAMS` of the host command NAME. SCHEMA is the JSON schema of its input, from `info args` and `info default` of the proc and from `doc`: an argument with a default is optional, and `args` is an array. A command that is not a proc has one argument, the array `args` of its words. The text with no `doc` is `The command NAME.`}
        returns {A list of four items.}
        see {{ztcl::agent doc} {info args}}
        argument NAME {
            type {command name}
            summary {A command of the host.}
        }
        example {
            proc greet {name {times 1}} {}
            ztcl::agent describe greet
        } {greet {The command greet.} {{"type":"object","properties":{"name":{"type":"string"},"times":{"type":"string"}},"required":["name"]}} {{name required} {times optional}}}
        example {lindex [ztcl::agent describe set] 2} {{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"}}},"required":[]}}
        error {ztcl::agent describe nosuch} {no command "nosuch" for a tool} {ZTCL AGENT USAGE}
        error {
            proc g {a} {}
            ztcl::agent doc g x a bogus
            ztcl::agent describe g
        } {bad type "bogus"} {ZTCL AGENT SCHEMA}
        error {ztcl::agent describe} {wrong # args: should be "::ztcl::agent::describe name"} {TCL WRONGARGS}
    }

    subcommand check {
        synopsis {ztcl::agent check SCHEMA VALUE}
        summary {Gives a value when it matches a result schema.}
        description {Gives VALUE when it matches the result schema SCHEMA, else the error `ZTCL AGENT RESULT` with the path of the first value that does not match.}
        returns {VALUE.}
        see {{ztcl::agent schema}}
        argument SCHEMA {
            type {result schema}
            summary {A list of keys and types.}
        }
        argument VALUE {
            type dict
            summary {The value to check.}
        }
        example {ztcl::agent check {n int tags {list string}} {n 3 tags {a b}}} {n 3 tags {a b}}
        example {ztcl::agent check {d {dict {a bool}} x number} {d {a yes} x 1.5}} {d {a yes} x 1.5}
        error {ztcl::agent check {kind {enum a b}} {kind c}} {result.kind is not enum a b} {ZTCL AGENT RESULT}
        error {ztcl::agent check {n int} {n x}} {result.n is not int} {ZTCL AGENT RESULT}
        error {ztcl::agent check {n int} {n 1 m 2}} {result has the extra key "m"} {ZTCL AGENT RESULT}
        error {ztcl::agent check {n int} {}} {result has no key "n"} {ZTCL AGENT RESULT}
        error {ztcl::agent check {n bogus} {n 1}} {bad type "bogus" in -result} {ZTCL AGENT SCHEMA}
        error {ztcl::agent check {n int}} {wrong # args: should be "::ztcl::agent::check spec value ?path?"} {TCL WRONGARGS}
    }

    subcommand schema {
        synopsis {ztcl::agent schema SCHEMA}
        summary {Gives the JSON schema of a result schema.}
        description {Gives the JSON schema of the result schema SCHEMA, as the model sees it in the input schema of the tool `result`. Each key is required, and an object has no other key.}
        returns {A JSON text.}
        see {{ztcl::agent check} ztcl::json}
        argument SCHEMA {
            type {result schema}
            summary {A list of keys and types.}
        }
        example {ztcl::agent schema {n int}} {{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"],"additionalProperties":false}}
        example {ztcl::agent schema {k {enum a b} l {list number}}} {{"type":"object","properties":{"k":{"type":"string","enum":["a","b"]},"l":{"type":"array","items":{"type":"number"}}},"required":["k","l"],"additionalProperties":false}}
        error {ztcl::agent schema {n bogus}} {bad type "bogus"} {ZTCL AGENT SCHEMA}
        error {ztcl::agent schema} {wrong # args: should be "::ztcl::agent::schema spec"} {TCL WRONGARGS}
    }

    subcommand post {
        synopsis {ztcl::agent post URL HEADERS BODY}
        summary {Sends one HTTP/1.1 POST of a JSON body.}
        description {Sends one HTTP/1.1 POST of the JSON text BODY to URL, with the headers of the list HEADERS, and gives the dict `status N body TEXT`. `run` uses it. An odd list of headers is not checked (issue 741).}
        returns {A dict of status and body.}
        see {{ztcl::agent run} ztcl::tls}
        argument URL {
            type URL
            summary {An http or https URL.}
        }
        argument HEADERS {
            type {list of names and values}
            summary {The headers of the request.}
        }
        argument BODY {
            type {JSON text}
            summary {The body of the request.}
        }
        example {
            replies {{"ok":true}}
            set r [ztcl::agent post $url {x-api-key k} {{"a":1}}]
            list $r [lindex [requests] end 1]
        } {{status 200 body {{"ok":true}}} {{"a":1}}}
        error {ztcl::agent post ftp://x {} {}} {bad endpoint "ftp://x"} {ZTCL AGENT ENDPOINT}
        error {ztcl::agent post $url {a "b\nc"} {}} {a header has a line end} {ZTCL AGENT HEADER}
        error {ztcl::agent post} {wrong # args: should be "::ztcl::agent::post url headers body"} {TCL WRONGARGS}
    }
}
