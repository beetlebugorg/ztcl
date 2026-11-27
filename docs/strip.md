# Strip a program

`ztcl build --strip` writes the binary of a program with a runtime that has only the parts its scripts use. The build scans the scripts, maps each command, option, and `package require` to a feature, and builds the runtime from source with the other features left out. A call of a command that the build left out is an error that names the command and the flag that keeps it.

```sh
$ ztcl build --strip -o hello hello.tcl
strip: building the runtime (regexp,oo,coroutine,binary,clock,...)
strip: runtime 3086624 bytes, stripped 1236016 bytes (1850608 bytes less)
strip: kept (on by default): jit
strip: dropped (not used): regexp oo coroutine binary
strip: dropped (the program has no capability): clock interp event launch exec socket thread vm meter notify watch registry credential folder keychain defaults
strip: dropped (no package require): hello json vt probe disasm tls
hello: 1236273 bytes (x86_64-linux runtime: 1236016 bytes, payload: 257 bytes)
```

The strip mode needs the source of ztcl and Zig 0.17.0. The build looks for the source in the folder of `--src DIR`, then in the folder of the environment variable `ZTCL_SRC`, then two folders above the `ztcl` program (the `zig-out/bin/ztcl` of a build from source). Zig is the program of the environment variable `ZIG`, or `zig` on the `PATH`.

## The features

A feature is a group of commands, a capability, a built-in module, or the JIT. `src/features_table.zig` lists them.

| Feature | Kind | Commands and options |
|---|---|---|
| `regexp` | commands | `regexp`, `regsub`, and the `-regexp` options of `switch`, `lsearch`, and `array` |
| `oo` | commands | `oo::*`, `self`, `next`, `nextto`, `my`, `info object`, `info class` |
| `coroutine` | commands | `coroutine`, `yield`, `yieldto` |
| `binary` | commands | `binary` |
| `clock`, `interp`, `event`, `launch`, `exec`, `socket`, `thread`, `vm`, `meter`, `notify`, `watch`, `registry`, `credential`, `folder`, `keychain`, `defaults` | capability | The commands of the capability |
| `hello`, `json`, `vt`, `probe`, `disasm`, `tls` | module | The commands of the module |
| `jit` | engine | The JIT compiler |

The rules:

- A feature of the capability kind goes when the capability is not in `--allow`. The program cannot turn on a capability at run time, so it can never call the commands.
- A feature of the commands kind or the capability kind stays when the scan sees one of its commands or options.
- A module stays when a `package require` names it or an alias of it, or when the scan sees one of its commands.
- The JIT stays, unless `--no-jit` is on.
- A feature that a feature in the build needs stays too: `tls` needs `socket`.

## Dynamic sites

The scan reads each script of the command line and each embedded `.tcl` and `.tm` file. It walks the bodies of `proc`, `method`, `if`, `while`, `for`, `foreach`, `switch`, `try`, `catch`, `namespace eval`, and `dict for`, each `[...]`, and each `[...]` in an expression. Other literal words with spaces, such as a `-command` option, are walked for their commands too.

A dynamic site is code whose command the scan cannot see:

| Site | Example |
|---|---|
| A computed command name | `$w configure -text hi`, `[list puts] hi` |
| An eval of computed text | `eval $script`, `uplevel 1 $body`, `namespace eval ns $body` |
| A `package require` of a computed name | `package require $name` |
| A `source` of a computed path | `source [file join $dir lib.tcl]` |

The report lists each site with its file and line. By default, a computed command name or an eval of computed text keeps each feature of the commands kind and each feature of an allowed capability. A `package require` of a computed name keeps each module. A computed `source` path keeps no feature, since the scan reads each embedded script.

`--trust-scan` changes the rule for computed names and computed text: a feature stays when a literal word anywhere in the scripts names one of its commands. So `set cmd regexp; $cmd a b` keeps `regexp`, and `eval [string cat reg exp] ...` does not.

## Keep and drop

| Option | What it does |
|---|---|
| `--strip` | Builds the stripped runtime. |
| `--keep LIST` | Keeps the features of the list. A name can also be a command, which keeps its feature: `--keep regsub`. |
| `--keep-module LIST` | The same as `--keep`. |
| `--drop-module LIST` | Leaves out the features of the list, also when the scan sees them. |
| `--trust-scan` | Uses the rule of the literal words for the dynamic sites. |
| `--profile` | Runs the tests and keeps the features of the commands that ran (see below). |
| `--check` | Runs the tests against the stripped binary. |
| `--test FILE` | A test script, for `--check` and `--profile`. Give it more than once for more scripts. |
| `--check-timeout S` | The time limit of a test run, in seconds. The default is 120. |
| `--strip-manifest FILE` | The manifest. The default is `ztcl-strip.txt` in the current folder, when it exists. |
| `--src DIR` | The source folder of ztcl. |

The manifest has one setting on each line. A line that starts with `#` is a comment:

```text
# ztcl-strip.txt
keep regexp, clock
drop tls
test tests/all.tcl
trust
```

## The error of a stripped command

```sh
$ cat dropped.tcl
catch {regexp a a} e
puts $e
puts $::errorCode
puts [catch {switch -regexp x {x {}}} e]
puts $e
$ ztcl build --strip --drop-module regexp -o dropped dropped.tcl
$ ./dropped
command "regexp" is not in this build: the build left out the feature regexp (rebuild with --keep regexp)
ZTCL STRIPPED regexp regexp
1
"switch -regexp" is not in this build: the build left out the feature regexp (rebuild with --keep regexp)
```

The error code is `ZTCL STRIPPED feature command`. A command of a capability that the program does not have gives the usual error, `invalid command name "clock"`, as in a build with no strip.

## Check the result

`--check` builds a second binary of the stripped runtime with the tests as its scripts and the files and scripts of the program under `//zipfs:/app/`, and runs it. The check fails when the run exits with a code other than 0, or when its output has the error of a stripped command. With no test, the check runs the program itself with no arguments.

```sh
$ ztcl build --strip --check --test test.tcl --allow file,channels -o jot --embed jot.tcl main.tcl
...
check: the tests passed on the stripped runtime
```

A test can `source` a file of the program: `source [file join [file dirname [info script]] jot.tcl]`.

## Profile mode

`--profile` first builds a binary of the full runtime with the tests, and with an execution trace on each command of each feature. It runs the binary and reads the list of the commands that ran. A feature of the commands kind or the capability kind then stays when the scan sees one of its commands as a literal, or when one of its commands ran. In this mode a dynamic site keeps no feature. Use `--check` with the same tests to confirm the result.

```sh
$ cat dyn.tcl
set c [string cat reg exp]
puts [$c a+ caab]
$ ztcl build --strip --profile -o dyn dyn.tcl
profile: 1 commands of features ran
...
strip: kept (ran in the profile): regexp
```

## The cache

The runtime goes in a folder of the cache, named by a hash of the target and the list of the dropped features: `ZTCL_STRIP_CACHE`, or `ztcl/strip` in `XDG_CACHE_HOME`, in `LOCALAPPDATA`, or in `~/.cache`. Each build runs `zig build app-runtime` in that folder, so Zig rebuilds only what changed. With no source folder, the build uses a runtime in the cache as it is.

The runtime of the strip mode is the build step `app-runtime`:

```sh
zig build app-runtime -Dapp-target=aarch64-linux -Ddrop=regexp,oo --prefix out
```

It is ReleaseSmall and stripped, as the runtimes of `zig build runtimes`, and it runs only the payload of `ztcl build`: it has no shell and no tools. `-Ddrop` works on each build of ztcl, so `zig build -Ddrop=oo` builds a runner with no TclOO.

## WebAssembly

`ztcl build --wasm --strip` builds `zig build wasm -Ddrop=...` into the cache and uses its `ztcl.wasm` as the base. `--check` and `--profile` need a native target of this computer.

## Sizes and start times

The native sizes are of x86-64 Linux, with the runtime of `zig build app-runtime` (ReleaseSmall, stripped). The full runtime is the same build with no `-Ddrop`: 3,086,624 bytes. With each feature dropped, the runtime is 1,101,480 bytes. The start time is the mean of 300 runs of `perf stat -r 300`, on a computer with other work on it.

| Program | Full | Stripped | Start, full | Start, stripped | Features kept |
|---|---|---|---|---|---|
| hello world (`puts`) | 3,086,881 | 1,236,273 | 2.95 ms | 2.94 ms | jit |
| `jot` of the Learn course, `--allow file,channels`, `jot show` | 3,088,715 | 1,316,651 | 4.32 ms | 3.83 ms | jit, json |

The WebAssembly sizes are of `ztcl build --wasm`, with the `ztcl.wasm` of `zig build wasm` as the full base:

| Program | Full | Stripped |
|---|---|---|
| hello world | 1,481,490 | 716,693 |
| `jot` | 1,483,233 | 858,692 |

The size of a feature is the size of the full native runtime less the size with only that feature dropped:

| Feature | Bytes |
|---|---|
| `vt` | 493,528 |
| `tls` | 283,512 |
| `jit` | 127,920 |
| `oo` | 86,520 |
| `json` | 69,168 |
| `regexp` | 36,608 |

These rows are of a later commit, with a full runtime of 3,196,000 bytes:

| Feature | Bytes |
|---|---|
| `clock` | 46,088 |
| `interp` | 22,792 |
| `binary` | 19,832 |
| `exec` | 13,352 |
| `event` | 8,744 |

`coroutine` and `socket` change the size by less than 2 KB in this measure.

The start of a binary of `ztcl build` reads only the payload from the program file, so the size of the runtime has a small effect on the start time.
