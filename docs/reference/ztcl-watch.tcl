# The command reference: ztcl::watch. The format is in
# docs/dev/reference-format.md.

command ztcl::watch {
    area ztcl
    since 1.0.0-beta.1
    capability file
    flags {--root . --allow file,channels}
    synopsis {ztcl::watch SUBCOMMAND ?ARG ...?}
    summary {Gives the changes below a folder: the files and the folders that a program makes, changes, deletes, or moves.}
    description {
        The watches of folders. `add` starts a watch of a folder, and `changes` gives the events that wait, with no block, so a script reads them when it wants them, for example from an event loop or a timer. The module watches only folders that the file commands can reach.

        The command exists when the embedder turns on the capability `file`, and the `ztcl` program turns it on with `--allow file`. It needs no `package require`. On Linux a watch is an inotify descriptor, on macOS an FSEvents stream, and on Windows a handle of the folder with a read of `ReadDirectoryChangesW`. On WebAssembly and WASI, `add` gives the error `ZTCL WATCH UNAVAILABLE`.

        `add` gives a handle such as `watch1`, and the argument of `changes`, `fd`, and `remove` is a handle. The name of the subcommand is checked first, then the count of arguments, then the handle. An unknown subcommand gives `TCL LOOKUP SUBCOMMAND` with the word, and an unknown handle gives `ZTCL WATCH HANDLE`. A subcommand has no short form.

        The examples of this page run in an empty root folder with `--root . --allow file,channels`.
    }
    returns {The result of the subcommand.}
    page modules/watch/
    see {file glob open}
    example {
        file mkdir site
        set w [ztcl::watch add site]
        set f [open site/index.html w]; puts $f hello; close $f
        set c [ztcl::watch changes $w]
        ztcl::watch remove $w
        set c
    } {{created /site/index.html}}
    error {ztcl::watch} {wrong # args: should be "ztcl::watch add|changes|fd|remove ?arg ...?"} {TCL WRONGARGS}
    error {ztcl::watch bogus} {unknown subcommand "bogus": must be add, changes, fd, or remove} {TCL LOOKUP SUBCOMMAND bogus}
    error {ztcl::watch bogus watch9} {unknown subcommand "bogus": must be add, changes, fd, or remove} {TCL LOOKUP SUBCOMMAND bogus}
    error {
        file mkdir d
        ztcl::watch bogus [ztcl::watch add d]
    } {unknown subcommand "bogus": must be add, changes, fd, or remove} {TCL LOOKUP SUBCOMMAND bogus}

    subcommand add {
        synopsis {ztcl::watch add ?-recursive? PATH}
        summary {Starts a watch of a folder and gives its handle.}
        description {Starts a watch of the folder PATH and gives its handle, `watch1` for the first one. PATH follows the rules of `file` and `open`: with a root folder (`--root DIR`, or `fsroot.setRoot` in Zig), a path outside the root is an error, and a symlink cannot lead out of it. In host mode, PATH is a path of the host. `remove` closes the watch, and so does the end or the reset of the interpreter.}
        returns {The handle of the watch.}
        see {{ztcl::watch changes} {ztcl::watch remove}}
        argument PATH {
            type path
            summary {The folder to watch.}
        }
        example {
            file mkdir d
            string match watch* [ztcl::watch add d]
        } 1
        example {
            file mkdir d
            set w [ztcl::watch add d]
            file mkdir d/sub
            set f [open d/sub/x w]; close $f
            ztcl::watch changes $w
        } {{created /d/sub}}
        error {ztcl::watch add nosuch} {couldn't watch the folder: no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {
            set f [open f.txt w]; close $f
            ztcl::watch add f.txt
        } {couldn't watch the folder: not a directory} {POSIX ENOTDIR {not a directory}}
        error {ztcl::watch add ../..} {couldn't access "../..": permission denied} {POSIX EACCES {permission denied}}
        error {ztcl::watch add} {wrong # args: should be "ztcl::watch add ?-recursive? path"} {TCL WRONGARGS}
        error {ztcl::watch add -bogus x} {wrong # args: should be "ztcl::watch add ?-recursive? path"} {TCL WRONGARGS}
        option -recursive {
            type flag
            summary {Watches each folder below the folder too.}
            description {The watch covers each folder below PATH, and a folder that a program makes later gets a watch when its create event arrives. A file that a program makes in a new folder before that event arrives has no event of its own, and the new folder shows as `created`. On macOS and Windows the system watches the whole tree, so a new folder needs no step of its own.}
            example {
                file mkdir site
                set w [ztcl::watch add -recursive site]
                set f [open site/a.txt w]; puts $f 1; close $f
                set f [open site/a.txt a]; puts $f 2; close $f
                file mkdir site/css
                ztcl::watch changes $w
            } {{created /site/a.txt} {created /site/css}}
            error {
                file mkdir d
                ztcl::watch add -r d
            } {wrong # args: should be "ztcl::watch add ?-recursive? path"} {TCL WRONGARGS}
        }
    }

    subcommand changes {
        synopsis {ztcl::watch changes WATCHER}
        summary {Gives the events that wait, as a list of pairs of a kind and a path.}
        description {
            Reads the events that wait, with no block, and gives a list of pairs `KIND PATH`. Then the list of the watch is empty. KIND is one of:

            - `created`: a file or a folder was made, or moved into the folder;
            - `modified`: the data or the attributes of a file changed;
            - `deleted`: a file or a folder was deleted;
            - `moved`: a file or a folder was moved out of its folder; on Windows such a move gives `deleted`, since Windows reports it as a removal;
            - `overflow`: too many events came, and the path is `/`, so the script reads the folder again.

            The events of one path merge into one pair, in the order of the first event of each path. A create and then a change stay `created`, and a later delete or move replaces the kind. More than 4,096 pairs, or an overflow of the queue of the system, give the pair `{overflow /}`.

            With a root folder a path starts at the root, as `/site/index.html`, and in host mode a path is a path of the host. On macOS a change comes some milliseconds after it, so `changes` right after a write can give no pair yet, and a script that waits for a change calls `changes` again or waits on `fd`.
        }
        returns {A list of pairs of a kind and a path.}
        see {{ztcl::watch add} {ztcl::watch fd}}
        argument WATCHER {
            type handle
            summary {A handle from `add`.}
        }
        example {
            file mkdir d
            set w [ztcl::watch add d]
            set f [open d/a.txt w]; puts $f 1; close $f
            set a [ztcl::watch changes $w]
            set f [open d/a.txt w]; puts $f 2; close $f
            set b [ztcl::watch changes $w]
            file delete d/a.txt
            list $a $b [ztcl::watch changes $w] [ztcl::watch changes $w]
        } {{{created /d/a.txt}} {{modified /d/a.txt}} {{deleted /d/a.txt}} {}}
        example {
            file mkdir d
            set w [ztcl::watch add d]
            set f [open d/c w]; close $f
            file delete d/c
            ztcl::watch changes $w
        } {{deleted /d/c}}
        error {ztcl::watch changes watch9} {can not find watcher named "watch9"} {ZTCL WATCH HANDLE}
        error {ztcl::watch changes} {wrong # args: should be "ztcl::watch changes|fd|remove watcher"} {TCL WRONGARGS}
    }

    subcommand fd {
        synopsis {ztcl::watch fd WATCHER}
        summary {Gives the descriptor that an embedder can wait on.}
        description {Gives the number of the inotify descriptor on Linux, on macOS the read end of a pipe that gets a byte when the stream has changes, and on Windows the value of the handle of an event that is signaled when changes wait, for `WaitForSingleObject` or `MsgWaitForMultipleObjects`. An embedder can wait on it in its own event loop, and then call `changes`.}
        returns {An integer.}
        see {{ztcl::watch changes}}
        argument WATCHER {
            type handle
            summary {A handle from `add`.}
        }
        example {
            file mkdir d
            string is integer -strict [ztcl::watch fd [ztcl::watch add d]]
        } 1
        error {ztcl::watch fd nope} {can not find watcher named "nope"} {ZTCL WATCH HANDLE}
        error {ztcl::watch fd} {wrong # args: should be "ztcl::watch changes|fd|remove watcher"} {TCL WRONGARGS}
    }

    subcommand remove {
        synopsis {ztcl::watch remove WATCHER}
        summary {Stops a watch.}
        description {Stops the watch and closes its descriptor. The handle is then invalid.}
        returns {An empty string.}
        see {{ztcl::watch add}}
        argument WATCHER {
            type handle
            summary {A handle from `add`.}
        }
        example {
            file mkdir d
            set w [ztcl::watch add d]
            ztcl::watch remove $w
            catch {ztcl::watch changes $w} m
            set m
        } {can not find watcher named "watch1"}
        error {ztcl::watch remove watch9} {can not find watcher named "watch9"} {ZTCL WATCH HANDLE}
        error {ztcl::watch remove} {wrong # args: should be "ztcl::watch changes|fd|remove watcher"} {TCL WRONGARGS}
    }
}
