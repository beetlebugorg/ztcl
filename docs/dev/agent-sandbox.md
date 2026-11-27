# Plan: sandboxed agents (ztcl#216)

An LLM agent loop runs in an isolated thread that holds only the data that the host gives it. A prompt injection in that data can steer the agent, but the agent can reach only the tools of the host, each with the checks of the host, and no file, socket, or program of its own.

## The design of 2026-11-27

The comment of 2026-11-27 on ztcl#216 puts the harness in the language. The state of each part:

| Part | State |
|---|---|
| A tool is a Tcl command, and its schema comes from the language | Done: `-tools` names commands, `ztcl::agent describe` reads `info args` and `info default`, and `ztcl::agent doc` adds the text and the types. Next: a doc and types extension of `proc` (questions.md). |
| A permission is a capability, and a denied call is a Tcl error with `-errorcode` | Done: the thread has `-caps {}`, and each error goes to the model with its code and `errorInfo`. |
| The budget is compute units | Done: `-compute` and `-meter` (ztcl#243). Next: tokens on the meter. |
| The sandbox is the isolation level, and host tools cross as commands | Done for `interp` and `process`: a host tool is a command of the thread that yields to the host. `vm` waits for ztcl#209. |
| Each turn and call is a probe record on the tape (ztcl#256) | Next: the log entries are dicts for the tape; the tape API is a question for the debugger agent. |
| The loop is a coroutine on the event loop, with streaming and `interp cancel` | The loop of the thread is a coroutine. Next: the host loop on `fileevent`, `stream: true`, and cancel. |
| Errors are results | Done. |
| The safety net of ztcl#178 | Next, after ztcl#178. |
| One command | `ztcl::agent run`. |

## The API

```tcl
package require ztcl::agent
proc draft_reply {text} {save_draft $text; return "draft saved"}
ztcl::agent doc draft_reply "Save a draft reply. It does not send it." text string
set r [ztcl::agent run -endpoint $url -header [list x-api-key $key] -model $model \
    -prompt "Sort the email." -data [list email $text] -tools {draft_reply} \
    -result {category {enum spam work personal} summary string} -meter agents]
```

docs/modules/agent.md has each option.

## The loop

1. The host starts the thread with `thread::create -joinable -isolation process -caps {}`, sends it the core script, the `-setup` script, and `::agent::start` with the tool specs.
2. In the thread, `::agent::step` resumes the coroutine `::agent::loop`. Each host tool is a proc of the thread that yields `type tool name N args LIST`. The host runs `N {*}LIST` at the global level and gives back `code`, `result`, `errorcode`, and `errorinfo`; the proc returns the result or raises the error.
3. The loop yields `type model body JSON` for each request, `type local ...` after each call of a thread tool (for the log), and returns `type done result D` or `type error text T`.
4. The host checks each body, adds `model`, posts it, counts tokens, checks the result against `-result`, and logs each step.

## The result schema

A small form in Tcl, and the module gives the model the same schema as JSON:

- `string`, `int`, `number`, `bool`.
- `{enum A B C}`: one of the words.
- `{list TYPE}`: a list of values of TYPE.
- `{dict KEY TYPE ...}`: a dict with exactly these keys.

The top of `-result` is the body of a `dict`. A missing key, an extra key, or a wrong type is the error `ZTCL AGENT RESULT`.

## The threat model

The data of the thread is hostile. A hijacked agent, that is a thread whose code does what the data says, can:

- send any request body to the one endpoint, up to the limits of turns and tokens;
- call the tools of the host with any input, up to the limit of calls, and get their results;
- run code in the thread up to the compute and memory limits;
- give a result, which the host checks against the schema.

It cannot:

- reach any other address, file, or program: the thread has no capability, and at the `process` level the sandbox of the system holds it even after a bug in the interpreter ([Isolated threads](../isolation.md));
- read the headers or the key: they are only in the host;
- run a script in the host: the host reads only the action dicts of the protocol, and the module turns off the sends of the thread to the host (`-caps {}` has no `thread`, so the thread has no `thread::send`);
- call a tool that the host did not give, or go past a limit;
- give a result outside the schema.

What remains: the model endpoint gets the data of the thread (the host chose to send it there), and the tools of the host are as safe as their own checks. A tool that sends mail lets a hijacked agent send mail. Give tools that draft. Do not give tools that send.

## Steps

1. `thread::create -caps LIST`: the thread gets only the listed capabilities of its creator. (PR 1 of this issue.)
2. The module `ztcl::agent`: the HTTP client of the host (plain HTTP on `socket`, HTTPS on `ztcl::tls socket` when the build has it), the loop, the schema check, the log, and the tests with a fake model server that scripts tool calls. (PR 2.)
3. The docs page `docs/agents.md` with a recorded example. (PR 2.)
4. Later: `-isolation vm` when `thread::create` has the level `vm`; attestation (ztcl#180); the browser demo of the issue.

## Questions

- The name of the result tool: `result`. A host tool of the same name is an error.
- No streaming: each model call waits for the whole reply.
