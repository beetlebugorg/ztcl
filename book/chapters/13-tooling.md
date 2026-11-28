# Install the tooling and view environment information {#ch:tooling}

ztcl is one program. The same `ztcl` binary runs a script, starts an interactive shell, builds a native program from your scripts, compiles procs to WebAssembly, and runs a debugger. This part of the book shows each of these tools in turn, and this chapter starts at the beginning: it installs ztcl, checks the install, gives an overview of the subcommands of `ztcl`, and shows how to see the version and the settings that change how your scripts run.

The examples of this part use a shell. Each line that starts with `$` is a command, and the text after `#` on that line is a comment that explains it. Lines with no `$` are the output of the command before them. The build of this book runs each of these examples with the `ztcl` of the same commit and compares the output, so the output that you see here is the real output.{^run-checked examples}

## Install ztcl {#sec:install}

The quickest way to install ztcl{^installation} is a package manager. The Homebrew formula works on macOS and on Linux, and the Arch Linux package builds the `main` branch from source:

```sh
$ brew install beetlebugorg/tap/ztcl     # macOS or Linux
$ git clone https://github.com/beetlebugorg/ztcl
$ cd ztcl/packaging/arch/ztcl-git
$ makepkg -si                            # Arch Linux
```

Each release also has an archive for Linux on x86-64 and arm64, macOS on x86-64 and arm64, and Windows on x86-64, with a `SHA256SUMS` file that has the checksum of each archive.{^release archives} The Linux binaries are static: they link with musl and need no shared library.

```sh
$ R=https://github.com/beetlebugorg/ztcl/releases/download
$ A=ztcl-1.0.0-beta.1-x86_64-linux-musl.tar.gz
$ curl -LO $R/v1.0.0-beta.1/$A             # the archive
$ curl -LO $R/v1.0.0-beta.1/SHA256SUMS     # the checksums
$ sha256sum -c SHA256SUMS --ignore-missing
$ tar xzf $A
```

To get the features that are on `main` and not in a release yet, build ztcl from source.{^build from source} The build needs only Zig 0.17.0. It needs no other tool and no C library:

```sh
$ git clone https://github.com/beetlebugorg/ztcl
$ cd ztcl
$ zig build -Doptimize=ReleaseFast    # makes zig-out/bin/ztcl
$ zig build test                      # runs the unit tests
$ zig build wasm                      # makes zig-out/lib/ztcl.wasm
```

> [!HINT]
> A build with no `-Doptimize` flag is a debug build. It has the safety checks of Zig and runs much more slowly. Use it to work on ztcl itself, and use `-Doptimize=ReleaseFast` for the binary that runs your scripts.

> [!NOTE]
> Add `-Dtarget=aarch64-macos`, `-Dtarget=x86_64-windows`, or another target to the `zig build` command to cross-compile ztcl. One host builds the binary of each platform.

## Check the install {#sec:check}

Run a script to check the install. The file `sum.tcl` has a proc that adds the numbers below ten million:

```tcl
proc sum {n} {
    set total 0
    for {set i 0} {$i < $n} {incr i} {
        incr total $i
    }
    return $total
}
puts [sum 10000000]
```

Give the name of the file to `ztcl`. By default, ztcl compiles a hot proc to machine code with its JIT{^JIT}. The flag `--no-jit` turns the JIT off, and the result stays the same:

```sh run
$ ztcl sum.tcl                 # with the JIT
49999995000000
$ ztcl --no-jit sum.tcl        # in the interpreter only
49999995000000
```

ztcl follows Tcl 9.1 by default, and Tcl 8.6.16 with `--tcl 8.6`. A script can read the level with `info patchlevel`, as in tclsh:

```tcl run
puts "Tcl [info patchlevel], version [info tclversion]"
```

```output
Tcl 9.1.0, version 9.1
```

Run `ztcl` with no file to start the interactive shell.{^shell} The shell has a line editor, a history, and the completion of command names. Type `exit`, or press Ctrl-D on an empty line, to leave it.

## The ztcl command {#sec:command}

The first word after `ztcl` is a file or a subcommand. These forms work today:

- `ztcl FILE ARG...` runs a script with the arguments in `argv`, and `ztcl` with no file starts the shell.
- `ztcl build` makes one native binary from a Tcl program. The binary has the scripts and the files of the program in it, and it runs on a machine with no ztcl install. Chapter 17 covers it.
- `ztcl compile --wasm` compiles the procs of a script into a WebAssembly module.
- `ztcl debug` runs a script with probes and writes a report of the error, the stack, and the locals of each frame. With `--dap` it is a debugger for an editor, and with `--mcp` it gives the same tools to an agent.

The Go toolchain made a set of subcommands familiar: `test`, `fmt`, `vet`, `doc`, `bench`, `version`, `env`, `upgrade`, and `bug`. ztcl does not have these yet.{^subcommands} The rest of this part of the book describes each one at the place where it fits, with a note like this one:

> [!MISSING]
> `ztcl test` (issue #565), `ztcl fmt` (#566), `ztcl vet` (#567), `ztcl doc` (#568), `ztcl bench` (#569), `ztcl upgrade` (#570), and `ztcl bug` (#571). Each issue has the design of the command. The chapter and the command go in together.

## Set limits on the command line {#sec:limits}

The flags before the file name configure the interpreter. A script from a user or from the network can loop forever or use all of the memory, so the most important flags are the limits.{^limits} The compute limit counts compute units, a measure of the work of the interpreter, and the memory limit counts bytes:{^compute limit}

```sh run
$ ztcl --compute 1000 sum.tcl  # stop after 1,000 units
sum.tcl:3: compute limit reached
```

The script stops at the command that used the last unit, and `catch` and `try` cannot catch the limit. The default memory limit of the runner is 2 GiB, and `--mem` changes it.

A script also has no access to the host by default: no files, sockets, clock, or processes. The flag `--allow` turns on each capability{^capabilities} by name, and `--root DIR` keeps the file commands inside one folder:

```sh
$ ztcl --mem 67108864 hog.tcl         # at most 64 MiB
$ ztcl --allow channels,file --root . files.tcl
```

Part III explains the capabilities in full. The rest of this chapter uses them only to explain what a script can see of its host.

## View the version {#sec:version}

Today, the version of the Tcl language is the only version that a script can read. The version of the ztcl program itself, its commit, and the target of the build are in the name of the release archive, and nowhere else.{^version}

> [!MISSING]
> `ztcl version` (issue #563) prints the version, the Tcl level, the target, the build mode, and the commit on one line. `ztcl version -m PROGRAM` lists the modules and the capabilities of a binary that `ztcl build` made.

When the command is in, this section shows its output in the same form as the other examples:

```sh
$ ztcl version                 # the version of this binary
$ ztcl version -m ./myapp      # the modules of a program
```

## View environment information {#sec:env}

A script in ztcl runs in a sandbox, so the values that tclsh reads from the host are different. The array `tcl_platform`{^tcl_platform} has the same keys as in tclsh, but the operating system and the machine stay hidden from the script:

```tcl run
foreach key {engine os machine platform pointerSize} {
    puts [format "%-12s %s" $key $tcl_platform($key)]
}
```

```output
engine       ztcl
os           ztcl
machine      generic
platform     unix
pointerSize  8
```

This is on purpose. With no capability on, the output of a script depends only on the script, the seed, and the inputs of the embedder, so a script gives the same result on each host. See [](#sec:limits) for the flags that change this.

You still need the facts of the host and of the build when you report a bug or compare a benchmark: the target, the state of the JIT, the default limits, and the modules in the binary. The command for this is `ztcl env`.{^environment}

> [!MISSING]
> `ztcl env` (issue #564) prints these settings as `NAME=value` lines, `ztcl env NAME` prints one value, and `ztcl env -json` prints a JSON object for tools and agents.

```sh
$ ztcl env                      # each setting
$ ztcl env ZTCL_TARGET ZTCL_JIT # only these values
$ ztcl env -json                # one JSON object
```

> [!HINT]
> Until `ztcl env` is in, give the output of `ztcl` with `info patchlevel`, the name of the release archive, and the `zig build` flags in a bug report.
