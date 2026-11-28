# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::agent {
    area ztcl
    since TODO
    synopsis {ztcl::agent subcommand ?arg ...?}
    summary {Runs an LLM agent loop in an isolated thread with no capability, which holds only the data and the tools that the host gives it.}
    description {Runs an LLM agent loop in an isolated thread with no capability, which holds only the data and the tools that the host gives it. The host posts each request to its one endpoint with its own headers, runs only its own tools, and checks the result against a schema. Load it with `package require ztcl::agent`.}
    capability {thread}
    page {modules/agent.md}
    flags {--allow thread}
    example {package require ztcl::agent; ztcl::agent check {n int tags {list string}} {n 3 tags {a b}}} {n 3 tags {a b}}
    example {catch {ztcl::agent check {kind {enum a b}} {kind c}} msg; set msg} {result.kind is not enum a b}
    example {proc greet {name {times 1}} {}; lindex [ztcl::agent describe greet] 3} {{name required} {times optional}}
    example {ztcl::agent schema {n int}} {{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"],"additionalProperties":false}}
    subcommand run {
        synopsis {ztcl::agent run ?-option value ...?}
        summary {Runs the loop.}
        description {Runs the loop. Gives a dict of the result, the log, and the counts.}
    }
    subcommand doc {
        synopsis {ztcl::agent doc NAME TEXT ?ARG TYPE ...?}
        summary {Sets the text of the tool NAME and the types of its arguments.}
        description {Sets the text of the tool NAME and the types of its arguments.}
    }
    subcommand describe {
        synopsis {ztcl::agent describe NAME}
        summary {The spec of the command NAME as a tool: name, text, JSON schema, and parameters.}
        description {The spec of the command NAME as a tool: name, text, JSON schema, and parameters.}
    }
    subcommand check {
        synopsis {ztcl::agent check SCHEMA VALUE}
        summary {VALUE when it matches the result schema SCHEMA, else the error `ZTCL AGENT RESULT`.}
        description {VALUE when it matches the result schema SCHEMA, else the error `ZTCL AGENT RESULT`.}
    }
    subcommand schema {
        synopsis {ztcl::agent schema SCHEMA}
        summary {The JSON schema of a result schema.}
        description {The JSON schema of a result schema.}
    }
    subcommand post {
        synopsis {ztcl::agent post URL HEADERS BODY}
        summary {One HTTP/1.1 POST of a JSON body.}
        description {One HTTP/1.1 POST of a JSON body. Gives `status N body TEXT`.}
    }
}
