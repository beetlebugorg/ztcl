# Ship it

`ztcl build` makes one static binary of a program: the runtime of ztcl and the scripts, with no install step. The binary has the sandbox of the interpreter, so its capabilities are part of the build. This lesson ships `jot`, and ends the course.

<!-- checkpoint -->
```tcl
```

## One binary

Put the procs of `jot` in `jot.tcl`, with `load` and `save` from the prompt of lesson 8, and a `main.tcl` that reads the command line:

```tcl
source [file join [file dirname [info script]] jot.tcl]
jot load
jot {*}$argv
jot save
```

Build it with the capabilities that it needs, and its folder:

```sh
ztcl build --allow file,channels -o jot --embed jot.tcl main.tcl
./jot add "buy milk"
```

`--embed` puts a file in the binary, under `//zipfs:/app/`. `info script` in `main.tcl` is `//zipfs:/app/main.tcl`, so `source` of a file next to it reads the embedded file. The binary has `file` and channels, and no network or `exec`. `--root PATH` keeps its files in one folder. `--target aarch64-macos` or `--target x86_64-windows` builds for another platform from the same computer. [Build a program](../build.md) has each option.

`{*}$argv` passes the words of the command line as the subcommand and its arguments. The ensemble of `jot` accepts only its exported procs, so a word such as `exec` is an error. This is one of the few right places for `{*}` with input: the first word goes to an ensemble with a fixed list.

## The JIT and threads, in short

- `ztcl --jit` compiles hot procs to machine code. The results, the errors, and the compute units are the same as in the interpreter. [The JIT](../jit.md) has the numbers.
- `thread::create` runs a script in its own interpreter, with its own limits. Threads share data with messages and `tsv`. [Threads](../threads.md) has the isolation levels.

## Reading code an agent wrote

- The build command lists the capabilities. Compare it with the commands that the scripts use.
- A program that has `file` has a `--root`, or a reason to use the real paths of the host.
- `{*}$argv` goes to an ensemble or a `switch` with a fixed list, and never to `eval`.

## Ask an agent

> Write the `ztcl build` command for `jot` with only the capabilities that its scripts use, and list each capability with the command that needs it.

## Try this

- Build a program with no `--allow`, and read the error of its first `open`.
- Build `jot` with `--jit`, and run it again.
- Go on to the advanced track: [Write a package](90-write-a-package.md).
