# A small service

`socket -server` answers connections on a port, and the event loop calls a proc for each line that comes in. This lesson makes `jot` answer on a port with a line protocol: `list`, and `add TEXT`. It is also the lesson about input that becomes code.

The shell of this page has no network and no event loop, so this lesson runs in `ztcl` on your computer. Issue [#245](https://github.com/beetlebugorg/ztcl/issues/245) adds a pair of channels in memory to the shell, for a server and a client in one page.

<!-- checkpoint -->
```tcl
```

## The server and a client

The script makes the server on a free port of the loopback address, connects a client to it, and sends four lines. Save it as `jot-server.tcl`, and run `ztcl --allow socket,event,channels jot-server.tcl`.

<!-- run: --allow socket,event,channels -->
```tcl
set notes [list "buy milk" "fix the bike"]
proc serve {chan addr port} {
    fconfigure $chan -buffering line
    fileevent $chan readable [list answer $chan]
}
proc answer {chan} {
    global notes
    if {[gets $chan line] < 0} { close $chan; return }
    if {![regexp {^(\w+) ?(.*)$} $line -> cmd arg]} { set cmd "" }
    switch -- $cmd {
        list    { puts $chan [join $notes " | "] }
        add     { lappend notes $arg; puts $chan "ok [llength $notes]" }
        default { puts $chan "error: unknown command" }
    }
}
set server [socket -server serve -myaddr 127.0.0.1 0]
set port [lindex [fconfigure $server -sockname] 2]

set c [socket 127.0.0.1 $port]
fconfigure $c -buffering line
fileevent $c readable [list apply {{c} { set ::got [gets $c] }} $c]
foreach line {list {add call Ada} {add [exit]} list} {
    puts $c $line
    vwait ::got
    puts "$line -> $::got"
}
close $c
close $server
```

```text
list -> buy milk | fix the bike
add call Ada -> ok 3
add [exit] -> ok 4
list -> buy milk | fix the bike | call Ada | [exit]
```

Port 0 asks the system for a free port, and `fconfigure $server -sockname` gives it. For a server that stays up, use a fixed port, put `vwait forever` at the end in place of the client, and connect with `nc 127.0.0.1 PORT`.

## Input that becomes code

The line `add [exit]` is text in a note, and the server goes on. `answer` reads the line with `regexp`, and passes `$arg` as one value to `lappend`. A Tcl command never runs the text of a value unless code asks for it.

Code that asks for it looks like one of these lines. Each one runs `exit`, or any other command, from a client:

- `eval $line` or `{*}$line`: the line is a command.
- `expr $arg` with no braces: the text goes through substitution.
- `uplevel #0 "set last $arg"`: a script built with quotes.
- `[lindex $line 0] {*}[lrange $line 1 end]`: the first word is any command.

The `switch` of `answer` lets in only the commands of the protocol. A line that is not a list, such as `add "a {b`, also stays text, because `answer` uses `regexp` and no list command on the line.

## Sockets are a capability

`socket` needs the `socket` capability, and the network policy of ztcl allows only the loopback address by default. `ztcl --net any` allows each address. An app that embeds ztcl sets an allowlist of hosts and ports. [Limits and capabilities](../limits.md) has the table.

## Reading code an agent wrote

- A line from the network goes to no `eval`, `uplevel`, `subst`, `expr` without braces, or `{*}` in the command position.
- The server checks each command name against a list, with `switch` or `dict exists`.
- A list command (`lindex`, `llength`, `foreach`) on a line from the network can give an error for a line that is not a list. The code parses the line with `regexp`, `split`, or `string`.
- Each `gets` checks for -1 and closes the channel.

## Ask an agent

> Write a Tcl line server for `jot` with the commands `list`, `add TEXT`, and `done N`. Parse each line with `regexp`, allow only these commands with `switch`, and never pass the line to `eval`, `expr`, or `{*}`.

## Try this

- Change `answer` to run `{*}$line`, and send `set notes {}`. Change it back.
- Add the command `count` to the protocol.
- Send the line `add "a {b`, and read the answer.
