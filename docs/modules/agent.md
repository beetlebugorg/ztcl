# Module ztcl::agent

`ztcl::agent` runs an LLM agent loop in an isolated thread that has only the data and the tools that the host gives it. [Sandboxed agents](../agents.md) is the guide, with a recorded run.

```tcl
package require ztcl::agent
proc draft_reply {text} {save_draft $text; return "draft saved"}
ztcl::agent doc draft_reply "Save a draft reply. It does not send it." text string
set r [ztcl::agent run -endpoint https://api.example.com/v1/messages \
    -header [list x-api-key $key anthropic-version 2023-06-01] -model $model \
    -prompt "Sort this email." -data [list email $text] -tools {draft_reply} \
    -result {category {enum spam work personal} summary string}]
dict get $r result
```

The module needs `ztcl::json` in the build: in a build without it, `package require ztcl::agent` gives an error. It needs the capability `thread` in the host. The host posts to the endpoint, so it also needs `socket` and `channels`, and its network policy must allow the endpoint. An `https` endpoint needs the module `ztcl::tls`.

## Commands

```tcl
ztcl::agent run ?-option value ...?
ztcl::agent doc NAME TEXT ?ARG TYPE ...?
ztcl::agent describe NAME
ztcl::agent check SCHEMA VALUE
ztcl::agent schema SCHEMA
ztcl::agent post URL HEADERS BODY
```

- `run` runs the loop and gives a dict: `result` (the checked result), `log` (a list of dicts, one for each model call, tool call, and the result), `turns`, `calls`, `input_tokens`, and `output_tokens`.
- `doc` sets the text of the tool NAME and the types of its arguments, for its schema. An argument with no type is a `string`.
- `describe` gives the spec of the host command NAME as a tool: `NAME TEXT SCHEMA PARAMS`. SCHEMA is JSON from `info args` and `info default` of the proc and from `doc`: an argument with a default is optional, and `args` is an array. A command that is not a proc has one argument: an array `args` of words.
- `check` gives VALUE when it matches the result schema SCHEMA, and the error `ZTCL AGENT RESULT` otherwise.
- `schema` gives the JSON schema of a result schema, as the model sees it.
- `post` sends one HTTP/1.1 POST with a JSON body and gives `status N body TEXT`. `run` uses it.

## Options of run

| Option | Value | Default |
|---|---|---|
| `-endpoint URL` | The one URL of the model, `http://` or `https://`. | none: it is needed |
| `-header LIST` | The headers of the host, such as the key, as names and values. The thread never gets them. | none |
| `-model NAME` | The `model` field that the host puts in each request. | none |
| `-system TEXT` | The system text. | none |
| `-prompt TEXT` | The first user text. | none |
| `-data LIST` | Names and values. Each value goes in the first user message as `<data name="NAME">`. | none |
| `-tools LIST` | The names of host commands. The thread gets a command of each name, and a call runs the command of the host at the global level with the words from the input of the model. | none |
| `-local LIST` | The names of commands of the thread, made by `-setup`, that the model can call. | none |
| `-setup SCRIPT` | A script that runs in the thread before the loop. It can use `::agent::doc` in place of `ztcl::agent doc`. | none |
| `-api FORM` | `messages` (the Messages API) or `openai` (chat completions, as llama-server serves it). | `messages` |
| `-result SCHEMA` | The schema of the result. | `answer string` |
| `-isolation LEVEL` | `process` or `interp`. | `process` |
| `-compute UNITS` | The compute limit of the thread. | the limit of the thread group |
| `-meter NAME` | A meter of [ztcl::meter](meter.md), with the capability `meter`. | none |
| `-turns N` | The most model calls. | 8 |
| `-calls N` | The most tool calls, of the host and of the thread. | 16 |
| `-tokens N` | The most tokens: the sum of `usage.input_tokens` and `usage.output_tokens` of the replies. | 100,000 |
| `-max-tokens N` | The `max_tokens` field of each request. | 4,096 |
| `-log CMD` | A command prefix that gets each entry of the log at once. | none |

The thread starts with `thread::create -caps {}`: it has no file, socket, program, clock, or thread command, so it has no `thread::send` to the host.

## The result schema

A result schema is a list of keys and types. A type is one of:

- `string`, `int`, `number`, `bool`;
- `{enum WORD ...}`: one of the words;
- `{list TYPE}`: a list of values of TYPE;
- `{dict SCHEMA}`: a dict with the keys of SCHEMA.

A dict has exactly the keys of its schema. The model gives its result with the tool `result`, whose input schema is `ztcl::agent schema SCHEMA`. A host tool or a thread tool cannot have the name `result`.

## The log

Each entry is a dict with `kind`:

- `model`: `turn`, `status`, `input_tokens`, `output_tokens`.
- `tool`: `where` (`host` or `thread`), `name`, `args` (the words of the call), `ok` (1 or 0), `result`, and `errorcode`. A call of a name that the thread has no command for has `ok 0`, the result `invalid command name "NAME"`, and the code `TCL LOOKUP COMMAND`. The model gets each error as the result of its call, with the error code and `errorInfo`.
- `result`: `ok`, and `error` when the result does not match the schema.

## The protocol

With `-api messages`, the requests have `messages` with `tool_use` and `tool_result` blocks and `tools` with `input_schema`, and the token counts are `usage.input_tokens` and `usage.output_tokens`. With `-api openai`, they have `messages` with `tool_calls` and `tool` messages and `tools` of type `function`, and the counts are `usage.prompt_tokens` and `usage.completion_tokens`. The loop ends when the model calls the tool `result`. A reply with no tool call gets one more user message that asks for the result tool, and a second such reply is the error `ZTCL AGENT MODEL`.

## Errors

| `errorCode` | When |
|---|---|
| `ZTCL AGENT USAGE` | A bad option, no `-endpoint`, a tool named `result`, or a name of `-tools` with no command. |
| `ZTCL AGENT ENDPOINT` | A bad URL, or `https` with no `ztcl::tls`. |
| `ZTCL AGENT HTTP` | The endpoint gave no HTTP status line. |
| `ZTCL AGENT HEADER` | A header has a line end. |
| `ZTCL AGENT MODEL` | A status other than 200, a reply with no content, or no result. |
| `ZTCL AGENT LIMIT turns`, `calls`, `tokens` | A limit of the options. |
| `ZTCL AGENT LIMIT thread` | The thread ended: its compute limit, its memory limit, or a crash of its child process. |
| `ZTCL AGENT RESULT` | The result does not match the schema. |
| `ZTCL AGENT PROTOCOL` | The thread gave an action outside the protocol. |
| `ZTCL AGENT SCHEMA` | A bad type in `-result`. |
