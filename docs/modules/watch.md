# Module ztcl::watch

`ztcl::watch` gives the changes below a folder: the files and the folders that a program makes, changes, deletes, or moves. A script reads the changes when it wants them, for example from an event loop or a timer. It needs the capability `file`, and it watches only folders that the file commands can reach.

> [!NOTE]
> `ztcl::watch` works on Linux, macOS, and Windows. On WebAssembly, `add` gives the error `ZTCL WATCH UNAVAILABLE`. The designs of the other platforms are in the plan of the repository (`docs/dev/watch.md`).

<!-- run: --root . --allow file,channels -->
```tcl
file mkdir site
set w [ztcl::watch add site]
set f [open site/index.html w]
puts $f hello
close $f
puts [ztcl::watch changes $w]
ztcl::watch remove $w
```

```text
{created /site/index.html}
```

## Synopsis

```tcl
ztcl::watch add ?-recursive? PATH
ztcl::watch changes W
ztcl::watch fd W
ztcl::watch remove W
```

`W` is a handle from `add`. The command exists when the embedder turns on `file`. The `ztcl` program turns it on with `--allow file`.

## Commands

### add

```tcl
ztcl::watch add ?-recursive? PATH
```

Starts a watch of the folder `PATH` and gives its handle, `watch1` for the first one. `PATH` goes through the same rules as `file` and `open`: with a root folder (`--root DIR`, or `fsroot.setRoot` in Zig), a path outside the root is an error, and a symlink cannot lead out of it. In host mode, `PATH` is a path of the host.

With `-recursive`, the watch covers each folder below `PATH`, and a folder that a program makes later gets a watch when its create event arrives. A file that a program makes in a new folder before that event arrives has no event of its own. The new folder shows as `created`.

On Linux, each watch is an inotify descriptor. On macOS, each watch is an FSEvents stream. On Windows, each watch is a handle of the folder with a read of `ReadDirectoryChangesW` that waits on an I/O completion port. `remove` closes it, and so does the end or the reset of the interpreter.

### changes

```tcl
ztcl::watch changes W
```

Reads the events that wait, with no block, and gives a list of pairs `KIND PATH`. Then the list of the watch is empty. `KIND` is one of:

| Kind | Event |
|---|---|
| `created` | A file or a folder was made, or moved into the watched folder. |
| `modified` | The data or the attributes of a file changed. |
| `deleted` | A file or a folder was deleted. |
| `moved` | A file or a folder was moved out of its folder. |
| `overflow` | Too many events came. The path is `/`. Read the folder again. |

The events of one path merge into one pair, in the order of the first event of each path. A create and then a change stay `created`. A later delete or move replaces the kind. More than 4,096 pairs, or an overflow of the kernel queue, give the one pair `{overflow /}`.

With a root folder, a path starts at the root, as `/site/index.html`. In host mode, a path is a path of the host.

<!-- run: --root . --allow file,channels -->
```tcl
file mkdir site
set w [ztcl::watch add -recursive site]
set f [open site/a.txt w]; puts $f 1; close $f
set f [open site/a.txt a]; puts $f 2; close $f
file mkdir site/css
puts [ztcl::watch changes $w]
file delete site/a.txt
puts [ztcl::watch changes $w]
puts [llength [ztcl::watch changes $w]]
```

```text
{created /site/a.txt} {created /site/css}
{deleted /site/a.txt}
0
```

### fd

```tcl
ztcl::watch fd W
```

Gives the number of the inotify descriptor on Linux, on macOS the read end of a pipe that gets a byte when the stream has changes, and on Windows the value of the handle of an event that is signaled when changes wait (for `WaitForSingleObject` or `MsgWaitForMultipleObjects`). An embedder can wait on it in its own event loop, and then call `changes`.

### remove

```tcl
ztcl::watch remove W
```

Stops the watch and closes its descriptor. The result is empty, and the handle is then invalid.

## Try the commands

The browser has no folders to watch, so the commands of this helper do not run in the page. The helper builds the commands for a folder under a root folder (`ztcl --root DIR --allow file`), and shows the result of `changes` after one action of a program, from the rules above.

<!-- helper: Watch a folder | Type a folder, pick what the program does, and see the ztcl::watch script. -->
```tcl
# shell: none
# height: 215
helper::form
helper::row Folder [ttk::entry .f.dir -textvariable dir -font TkFixedFont]
helper::row "" [ttk::checkbutton .f.rec -text -recursive -variable rec]
helper::row "A program" [ttk::combobox .f.act -textvariable act -state readonly -values {
    "makes a.txt" "changes a.txt" "deletes a.txt" "moves a.txt out"
    "makes a.txt, then changes it" "makes and deletes a.txt"
}]
helper::footer 3 0
set dir /site
set rec 0
set act "makes a.txt, then changes it"
proc build {} {
    set add [list ztcl::watch add]
    if {$::rec} { lappend add -recursive }
    lappend add $::dir
    set helper::cmd "set w \[$add\]; ztcl::watch changes \$w"
    set path [string trimright $::dir /]/a.txt
    switch -- $::act {
        "makes a.txt" - "makes a.txt, then changes it" { set kind created }
        "changes a.txt" { set kind modified }
        "deletes a.txt" - "makes and deletes a.txt" { set kind deleted }
        "moves a.txt out" { set kind moved }
    }
    helper::result 1 "add gives watch1, and changes gives:\n[list $kind $path]"
}
helper::watch build dir rec act
```

## Errors

| Error code | Message | Cause |
|---|---|---|
| `TCL WRONGARGS` | `wrong # args: should be "ztcl::watch add ?-recursive? path"` | A subcommand got the wrong count of arguments. |
| `NONE` | `bad option "X": must be add, changes, fd, or remove` | An unknown subcommand. |
| `NONE` | `can not find watcher named "X"` | A handle that `add` did not give, or a removed handle. |
| `POSIX ENOENT ...` | `couldn't watch the folder: no such file or directory` | `PATH` is not a folder. Each other error of the system has its POSIX code. |
| `POSIX EACCES ...` | `couldn't access "PATH": permission denied` | With a root folder, `PATH` is outside the root. |
| `ZTCL WATCH UNAVAILABLE` | `ztcl::watch is not available on this platform yet` | `add` on a platform with no backend. |

<!-- run: --root . --allow file,channels -->
```tcl
puts [catch {ztcl::watch add nosuch} m o]
puts $m
puts [lindex [dict get $o -errorcode] 1]
puts [catch {ztcl::watch changes watch9} m]
puts $m
```

```text
1
couldn't watch the folder: no such file or directory
ENOENT
1
can not find watcher named "watch9"
```

## Platforms

- Linux: inotify, in the runner and in each embedder that turns on `file`.
- Windows: `ReadDirectoryChangesW`, with `-recursive` as the watch of the subtree, so a new folder needs no step of its own. A change of the time of a folder, which Windows gives for each change in the folder, is no event, as on Linux. The file system keeps the changes between two calls of `changes` in a buffer, and a full buffer (64 KiB of records: more than 1,000 changes of names of 20 characters) gives `{overflow /}`.
- macOS: an FSEvents stream with the events of each file, on the real path of the folder, so a new folder needs no step of its own. FSEvents delivers a change some milliseconds after it (the stream asks for 50 ms at most), so `changes` right after a write can give nothing yet: a script that waits for a change calls `changes` again, or waits on `fd`. FSEvents merges the flags of one path, so the kind comes from the flags and the file: a path that was there before the watch and changes is `modified`. A dropped event of the system gives `{overflow /}`. CoreServices loads on the first `add`.
- WebAssembly and WASI: `add` gives `ZTCL WATCH UNAVAILABLE`, and `changes`, `fd`, and `remove` give `can not find watcher named "W"`.
