# Build a program

`ztcl build` writes one native binary from a Tcl program. The binary has the scripts and the files of the program in it, and it runs with no ztcl install and no script files on disk. One host builds the binary of each target, with no Zig toolchain.

The binary has the interpreter, and the JIT where the target has one. It does not yet have machine code compiled at build time. [The plan](dev/static-build.md) has that phase.

## A first program

`main.tcl`:

```tcl
puts "hello, $argv"
source [file join [file dirname [info script]] greet.tcl]
puts [greet [lindex $argv 0]]
```

`greet.tcl`:

```tcl
proc greet {who} {
    set f [open //zipfs:/app/data/greeting.txt]
    set text [string trim [read $f]]
    close $f
    return "$text, $who"
}
```

`data/greeting.txt` has the line `Good morning`.

```sh
$ ztcl build -o hello --embed greet.tcl --embed data main.tcl
hello: 1981951 bytes (x86_64-linux runtime: 1981240 bytes, payload: 703 bytes)
$ ./hello world
hello, world
Good morning, world
```

The scripts on the command line run in order, as `ztcl a.tcl b.tcl` runs them. Each file of `--embed`, and each script, is a read-only file under `//zipfs:/app/`, with its path as given. A folder adds each file below it. So `info script` in `main.tcl` is `//zipfs:/app/main.tcl`, and `source` of a path next to it reads the embedded file. The words after the program name are `$argv`, and the binary reads no option of its own.

## Other targets

`--target` gives the binary of another platform:

```sh
$ ztcl build --target aarch64-linux -o hello-arm64 --embed greet.tcl --embed data main.tcl
hello-arm64: 1559823 bytes (aarch64-linux runtime: 1559112 bytes, payload: 703 bytes)
$ ztcl build --target aarch64-macos -o hello-mac --embed greet.tcl --embed data main.tcl
hello-mac: 1751350 bytes (aarch64-macos runtime: 1740472 bytes, payload: 703 bytes)
$ ztcl build --target x86_64-windows -o hello.exe --embed greet.tcl --embed data main.tcl
hello.exe: 2106047 bytes (x86_64-windows runtime: 2105344 bytes, payload: 703 bytes)
```

The targets are `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`, `x86_64-windows`, and `aarch64-windows`. The default is the host.

Each target has a prebuilt runtime binary. `ztcl build` copies it, adds the payload (a zip archive of the scripts and the files), and writes the offset of the payload into the copy. It looks for the runtime of a target in this order:

1. The file of `--runtime FILE`.
2. `T/ztcl` (or `T/ztcl.exe`) in the folder of the environment variable `ZTCL_RUNTIME_DIR`.
3. `../lib/ztcl/runtime/T/` next to the folder of the `ztcl` program.
4. For the host target, the `ztcl` program itself.

A build from source makes the runtimes with `zig build runtimes`, into `zig-out/lib/ztcl/runtime/`.

The same input and target give the same bytes on each build.

## macOS and Windows

A binary for macOS has an ad hoc code signature, which `ztcl build` writes on each host. arm64 macOS runs it with no other step. A binary for other users needs a Developer ID signature and notarization. These are the usual commands on a Mac, after the build. The CI of ztcl does not run them:

```sh
codesign --force --options runtime --sign "Developer ID Application: NAME" hello-mac
xcrun notarytool submit hello-mac.zip --keychain-profile PROFILE --wait
```

The JIT needs writable and executable memory, so a binary with the hardened runtime (`--options runtime`) and `--jit` needs the entitlement `com.apple.security.cs.allow-jit`. This is not tested.

A binary for Windows has no signature. Sign it after the build with `signtool` or `osslsigncode`.

## Capabilities

A built program has the sandbox of the interpreter. By default it reads its own files under `//zipfs:/app/` and has no other access to the host:

```sh
$ cat when.tcl
puts [clock format 0 -gmt 1]
$ ztcl build -o when when.tcl
$ ./when
invalid command name "clock"
$ ztcl build --allow clock -o when when.tcl
$ ./when
Thu Jan 01 00:00:00 GMT 1970
```

| Option | What it does |
|---|---|
| `--allow LIST` | The capabilities of the program, with the names of `ztcl --allow` (see [Limits and capabilities](limits.md)). `embedded` is always on. |
| `--root PATH` | The root folder of `file` and channels at run time, a jail that `..` and symlinks cannot leave. Without it, a program with `file` uses the real paths of the host, as the `ztcl` runner does. |
| `--jit` | Turns on the JIT at start, on a target with a JIT. |
| `--compress` | Stores each file with deflate when that is smaller. The default stores each file as it is. |

## The files of a program

The mount `//zipfs:/app/` is read-only. `open` for reading, `source`, `glob`, and the queries of `file` (`exists`, `isfile`, `isdirectory`, `size`, `type`, `mtime`, `stat`, `readable`, `normalize`) work on it. A write is an error:

```sh
$ cat ls.tcl
puts [glob -directory //zipfs:/app -tails *]
puts [file size //zipfs:/app/data/greeting.txt]
puts [catch {open //zipfs:/app/new.txt w} msg]
puts $msg
$ ztcl build -o ls --embed data ls.tcl
$ ./ls
data ls.tcl
13
1
couldn't open "//zipfs:/app/new.txt": read-only file system
```

## Zip files at run time

The `zipfs` command mounts a zip file under `//zipfs:/`, as in Tcl 9. A mount of a file needs the `file` capability, and the zip file is a file inside the root folder:

```sh
$ cat mount.tcl
zipfs mount lib.zip lib
source //zipfs:/lib/hi.tcl
puts [zipfs list]
$ ztcl --allow channels,file --root . mount.tcl
from the zip
//zipfs:/lib/hi.tcl
```

| Command | What it does |
|---|---|
| `zipfs mount ?zipfile? ?mountpoint?` | Mounts a zip file. With one word, gives the zip file of a mount point. With none, gives the mounts. |
| `zipfs unmount mountpoint` | Removes a mount. The mount of a built program stays. |
| `zipfs list ?-glob? ?pattern?` | Gives the path of each file of each mount. |
| `zipfs info file` | Gives the zip file, the size, the compressed size, and the offset of a file. |
| `zipfs exists file` | Gives 1 for a file or a folder of a mount. |
| `zipfs root` | Gives `//zipfs:/`. |

The reader reads stored and deflate entries, zip64 sizes, and a zip archive after other bytes. An entry is decompressed into the memory of the interpreter, so the memory limit stops a zip bomb.

An embedder turns on the mounts with the capability `embedded` (reads of the mounts only) or `file`, and mounts its own memory with `ztcl.vfs.mountBytes`. See [Embed in Zig](embedding.md).
