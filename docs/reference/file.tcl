# The command reference: file. The format is in
# docs/dev/reference-format.md.

command file {
    area channels
    since 1.0.0-beta.1
    capability file
    flags {--root . --allow channels,file}
    synopsis {file SUBCOMMAND ?ARG ...?}
    summary {The commands for paths and files: names, tests, facts, and changes.}
    description {
        The commands for paths and files. The name commands `join`, `split`, `dirname`, `tail`, `extension`, `rootname`, and `pathtype` work on the text of a path and read no file. The other subcommands read or change the file system.

        A new interpreter has no `file`: the host turns on the capability `file`. In the root folder of the interpreter (`ztcl --root DIR`, or an embedder with `fsroot.setRoot`), each path is inside that folder: `/` is the root folder, a relative path starts at the working folder, and a path that leaves the root folder is an error. The `ztcl` program uses the paths of the host by default, as tclsh does.

        The separator of a path is `/` in the root folder and on Linux and macOS. In host mode on Windows, `separator` gives `\`, `nativename` gives the path with `\`, `volumes` gives the drives, and `system` gives the type of the volume, as tclsh does. A unique prefix of a subcommand is the subcommand. The examples of this page run in an empty root folder.
    }
    returns {The result of the subcommand.}
    see {open glob cd pwd {file channels} chan}
    difference {Links, the attributes of a file, and a new time with `atime` and `mtime` are errors in ztcl ([issue 687](https://github.com/beetlebugorg/ztcl/issues/687)).}
    difference {Tcl 9.0.4 has `file home`, `file tempdir`, and `file tildeexpand`, and ztcl has none of them ([issue 685](https://github.com/beetlebugorg/ztcl/issues/685)).}
    difference {Many errors have `-errorcode NONE` or a shorter code, where Tcl 8.6.16 and 9.0.4 give a code such as `TCL WRONGARGS` or `TCL LOOKUP SUBCOMMAND` ([issue 730](https://github.com/beetlebugorg/ztcl/issues/730)).}
    example {file join notes 2026 a.json} notes/2026/a.json
    example {file extension notes.json} .json
    example {
        file mkdir data
        file isdirectory data
    } 1
    example {file normalize a/../b/./c} /b/c -note {In the root folder, / is the root folder.}
    error {file bogus} {unknown or ambiguous subcommand "bogus": must be atime, attributes, channels, copy, delete, dirname, executable, exists, extension, isdirectory, isfile, join, link, lstat, mkdir, mtime, nativename, normalize, owned, pathtype, readable, readlink, rename, rootname, separator, size, split, stat, system, tail, tempfile, type, volumes, or writable} {TCL LOOKUP INDEX subcommand}
    error {file normalize ../../x} {couldn't access "../../x": permission denied} {POSIX EACCES {permission denied}} -note {A path that leaves the root folder.}

    subcommand join {
        synopsis {file join NAME ?NAME ...?}
        summary {Joins parts into one path.}
        description {Joins each NAME with `/`. A NAME that is an absolute path, such as `/b`, starts the path again and drops the parts before it. A `/` at the end of a part does not double. The result is text: `..` and `.` stay as they are.}
        returns {The path.}
        see {{file split} {file normalize}}
        argument NAME {
            type path
            repeats
            summary {A part of the path, at least one.}
        }
        example {file join notes 2026 a.json} notes/2026/a.json
        example {file join a /b c} /b/c
        example {file join a b/ c} a/b/c
        example {file join a ../b} a/../b
        error {file join} {wrong # args: should be "file join name ?name ...?"} {TCL WRONGARGS}
    }

    subcommand split {
        synopsis {file split NAME}
        summary {Gives the parts of a path as a list.}
        description {Gives the parts of NAME between the separators. An absolute path starts with the part `/`. Repeated separators and a separator at the end add no part. An empty NAME gives an empty list.}
        returns {The list of the parts.}
        see {{file join} {file dirname} {file tail}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file split notes/2026/a.json} {notes 2026 a.json}
        example {file split /a/b} {/ a b}
        example {file split a//b/} {a b}
        error {file split} {wrong # args: should be "file split name"} {TCL WRONGARGS}
    }

    subcommand dirname {
        synopsis {file dirname NAME}
        summary {Gives a path with no last part.}
        description {Gives NAME with its last part removed. A name of one relative part gives `.`, and `/a` and `/` give `/`.}
        returns {The path of the folder.}
        see {{file tail} {file split}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file dirname notes/2026/a.json} notes/2026
        example {file dirname a.json} .
        example {file dirname /a} /
        error {file dirname} {wrong # args: should be "file dirname name"} {TCL WRONGARGS}
    }

    subcommand tail {
        synopsis {file tail NAME}
        summary {Gives the last part of a path.}
        description {Gives the last part of NAME. A separator at the end does not count, so `notes/` gives `notes`.}
        returns {The last part.}
        see {{file dirname} {file rootname}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file tail notes/2026/a.json} a.json
        example {file tail notes/} notes
        error {file tail} {wrong # args: should be "file tail name"} {TCL WRONGARGS}
    }

    subcommand extension {
        synopsis {file extension NAME}
        summary {Gives the extension of the last part of a path, with its dot.}
        description {Gives the text from the last dot of the last part of NAME to its end, such as `.json`. A last part with no dot gives an empty string, and so does a dot in a folder name only. A last part that starts with its only dot, such as `.hidden`, is all extension.}
        returns {The extension with its dot, or an empty string.}
        see {{file rootname} {file tail}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file extension notes.json} .json
        example {file extension notes.tar.gz} .gz
        example {file extension a.b/c} {}
        example {file extension .hidden} .hidden
        error {file extension} {wrong # args: should be "file extension name"} {TCL WRONGARGS}
    }

    subcommand rootname {
        synopsis {file rootname NAME}
        summary {Gives a path with no extension.}
        description {Gives NAME with the extension of `file extension` removed. A name with no extension stays as it is.}
        returns {The path with no extension.}
        see {{file extension} {file tail}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file rootname notes.tar.gz} notes.tar
        example {file rootname a.b/c} a.b/c
        example {file rootname .hidden} {}
        error {file rootname} {wrong # args: should be "file rootname name"} {TCL WRONGARGS}
    }

    subcommand pathtype {
        synopsis {file pathtype NAME}
        summary {Gives the kind of a path: absolute, relative, or volumerelative.}
        description {Gives `absolute` for a path that starts with `/`, and `relative` for the others. With `--tcl 8.6`, a path that starts with `~` is `absolute`, since Tcl 8.6 expands `~` to a home folder. With `--tcl 9.1`, a `~` has no meaning, and `~` is relative. In host mode on Windows, a path with a drive such as `C:/a` is `absolute`, and `/a` is `volumerelative`, as in tclsh.}
        returns {absolute, relative, or volumerelative.}
        see {{file normalize} {file join}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file pathtype a/b} relative
        example {file pathtype /a} absolute
        example {file pathtype ~} absolute -tcl 8.6
        example {file pathtype ~} relative -tcl 9.1
        error {file pathtype} {wrong # args: should be "file pathtype name"} {TCL WRONGARGS}
    }

    subcommand normalize {
        synopsis {file normalize NAME}
        summary {Gives the full path with each . and .. removed.}
        description {Gives the absolute form of NAME: a relative path starts at the working folder, and each `.` and `..` part goes away. In the root folder the result starts at its `/`, and a path that leaves the root folder is an error. The file does not need to exist.}
        returns {The full path.}
        see {{file join} pwd {file pathtype}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file normalize a/../b/./c} /b/c
        example {file normalize /x/y} /x/y
        error {file normalize ../../x} {couldn't access "../../x": permission denied} {POSIX EACCES {permission denied}}
        error {file normalize} {wrong # args: should be "file normalize name"} {TCL WRONGARGS}
    }

    subcommand nativename {
        synopsis {file nativename NAME}
        summary {Gives a path in the form of the platform.}
        description {Gives NAME with the separator of the platform. In the root folder and on Linux and macOS the separator is `/`, so NAME stays as it is. In host mode on Windows, `C:/a/b` gives `C:\a\b`.}
        returns {The path.}
        see {{file separator}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file nativename a/b} a/b
        error {file nativename} {wrong # args: should be "file nativename name"} {TCL WRONGARGS}
    }

    subcommand separator {
        synopsis {file separator ?NAME?}
        summary {Gives the separator of paths.}
        description {Gives the separator of paths: `\` in host mode on Windows, and `/` in the root folder and on Linux and macOS. With NAME it gives the same separator.}
        returns {The separator.}
        see {{file nativename} {file join}}
        difference {Tcl 8.6.16 and 9.0.4 give an error for more than one argument ([issue 688](https://github.com/beetlebugorg/ztcl/issues/688)).}
        argument NAME {
            type path
            optional
            summary {A path of the file system to ask about.}
        }
        example {file separator} /
        example {file separator a/b} /
        noerrors {Each call gives the separator. ztcl does not check the count of arguments of this subcommand (issue 688).}
    }

    subcommand mkdir {
        synopsis {file mkdir ?DIR ...?}
        summary {Makes folders, with each missing parent folder.}
        description {Makes each DIR, and each missing folder on its path, as `mkdir -p` does. A DIR that is already a folder is no error. A DIR, or a folder of its path, that is a file is an error. With no DIR it gives an empty string and makes no folder.}
        returns {An empty string.}
        see {{file delete} {file isdirectory}}
        argument DIR {
            type path
            optional
            repeats
            summary {A folder to make.}
        }
        example {
            file mkdir d1/d2/d3
            file isdirectory d1/d2/d3
        } 1
        example {
            file mkdir a/b
            file mkdir a/b
        } {} -note {A folder that exists is no error.}
        error {
            set f [open x w]; close $f
            file mkdir x
        } {can't create directory "x": file already exists} {POSIX EEXIST {file already exists}}
    }

    subcommand exists {
        synopsis {file exists NAME}
        summary {Tests whether a file or a folder exists.}
        description {Gives 1 when NAME is a file, a folder, or another entry of the file system, else 0. A path that leaves the root folder gives 0.}
        returns {1 or 0.}
        see {{file isfile} {file isdirectory}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            file exists n.txt
        } 1
        example {file exists nope.txt} 0
        error {file exists} {wrong # args: should be "file exists name"} {TCL WRONGARGS}
    }

    subcommand isfile {
        synopsis {file isfile NAME}
        summary {Tests whether a path is a file.}
        description {Gives 1 when NAME is a regular file, else 0, also when NAME does not exist.}
        returns {1 or 0.}
        see {{file isdirectory} {file type}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            file isfile n.txt
        } 1
        example {
            file mkdir data
            file isfile data
        } 0
        error {file isfile} {wrong # args: should be "file isfile name"} {TCL WRONGARGS}
    }

    subcommand isdirectory {
        synopsis {file isdirectory NAME}
        summary {Tests whether a path is a folder.}
        description {Gives 1 when NAME is a folder, else 0, also when NAME does not exist.}
        returns {1 or 0.}
        see {{file isfile} {file mkdir}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            file mkdir data
            file isdirectory data
        } 1
        example {file isdirectory nope} 0
        error {file isdirectory} {wrong # args: should be "file isdirectory name"} {TCL WRONGARGS}
    }

    subcommand readable {
        synopsis {file readable NAME}
        summary {Tests whether a file can be read.}
        description {Gives 1 when NAME exists and its permissions let a process read it, else 0.}
        returns {1 or 0.}
        see {{file writable} {file executable}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            file readable n.txt
        } 1
        example {file readable nope.txt} 0
        error {file readable} {wrong # args: should be "file readable name"} {TCL WRONGARGS}
    }

    subcommand writable {
        synopsis {file writable NAME}
        summary {Tests whether a file can be written.}
        description {Gives 1 when NAME exists and its permissions let a process write it, else 0.}
        returns {1 or 0.}
        see {{file readable}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            file writable n.txt
        } 1
        example {file writable nope.txt} 0
        error {file writable} {wrong # args: should be "file writable name"} {TCL WRONGARGS}
    }

    subcommand executable {
        synopsis {file executable NAME}
        summary {Tests whether a file has a permission to run.}
        description {Gives 1 when NAME exists and has a permission to run, else 0. A new file of `open` has none.}
        returns {1 or 0.}
        see {{file readable} exec}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            file executable n.txt
        } 0
        error {file executable} {wrong # args: should be "file executable name"} {TCL WRONGARGS}
    }

    subcommand owned {
        synopsis {file owned NAME}
        summary {Tests whether a file exists and is of the user.}
        description {Gives 1 when NAME exists and belongs to the user of the process, else 0.}
        returns {1 or 0.}
        see {{file stat}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            file owned n.txt
        } 1
        example {file owned nope.txt} 0
        error {file owned} {wrong # args: should be "file owned name"} {TCL WRONGARGS}
    }

    subcommand size {
        synopsis {file size NAME}
        summary {Gives the size of a file in bytes.}
        description {Gives the count of bytes of the file NAME. A missing file is an error.}
        returns {A non-negative integer.}
        see {{file stat} {string length}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; puts -nonewline $f hello; close $f
            file size n.txt
        } 5
        error {file size nope.txt} {could not read "nope.txt": no such file or directory} {POSIX ENOENT {no such file or directory}}
    }

    subcommand type {
        synopsis {file type NAME}
        summary {Gives the kind of an entry of the file system: file, directory, link, and others.}
        description {Gives `file`, `directory`, `link`, `characterSpecial`, `blockSpecial`, `fifo`, or `socket` for NAME. A missing file is an error.}
        returns {The kind of the entry.}
        see {{file isfile} {file stat}}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            file type n.txt
        } file
        example {
            file mkdir data
            file type data
        } directory
        error {file type nope.txt} {could not read "nope.txt": no such file or directory} {POSIX ENOENT {no such file or directory}}
    }

    subcommand mtime {
        synopsis {file mtime NAME}
        summary {Gives the time of the last change of a file, in seconds.}
        description {Gives the time of the last change of the content of NAME, in seconds since 1970-01-01 UTC. A missing file is an error. A new time as a second argument is an error in ztcl.}
        returns {An integer of seconds.}
        see {{file atime} {file stat} clock}
        difference {Tcl 8.6.16 and 9.0.4 set the time with `file mtime NAME TIME` ([issue 687](https://github.com/beetlebugorg/ztcl/issues/687)).}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            expr {[file mtime n.txt] > 0}
        } 1
        error {file mtime nope.txt} {could not read "nope.txt": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {file mtime n.txt 1700000000} {file mtime with a new time is not available} NONE
    }

    subcommand atime {
        synopsis {file atime NAME}
        summary {Gives the time of the last read of a file, in seconds.}
        description {Gives the time of the last access to NAME, in seconds since 1970-01-01 UTC. A missing file is an error. A new time as a second argument is an error in ztcl.}
        returns {An integer of seconds.}
        see {{file mtime} {file stat}}
        difference {Tcl 8.6.16 and 9.0.4 set the time with `file atime NAME TIME` ([issue 687](https://github.com/beetlebugorg/ztcl/issues/687)).}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            expr {[file atime n.txt] > 0}
        } 1
        error {file atime nope.txt} {could not read "nope.txt": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {file atime n.txt 1700000000} {file atime with a new time is not available} NONE
    }

    subcommand stat {
        synopsis {file stat NAME VAR}
        summary {Puts the facts of a file in an array.}
        description {Sets the elements of the array VAR to the facts of NAME: `atime`, `ctime`, `dev`, `gid`, `ino`, `mode`, `mtime`, `nlink`, `size`, `type`, and `uid`. A missing file is an error.}
        returns {An empty string.}
        see {{file lstat} {file size} {file type}}
        argument NAME {
            type path
            summary {The path.}
        }
        argument VAR {
            type {array name}
            summary {The array for the facts.}
        }
        example {
            set f [open n.txt w]; puts -nonewline $f hello; close $f
            file stat n.txt st
            list $st(size) $st(type)
        } {5 file}
        example {
            set f [open q w]; close $f
            file stat q s
            lsort [array names s]
        } {atime ctime dev gid ino mode mtime nlink size type uid}
        error {file stat nope.txt st} {could not read "nope.txt": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {file stat nope.txt} {wrong # args: should be "file stat name varName"} NONE
    }

    subcommand lstat {
        synopsis {file lstat NAME VAR}
        summary {Puts the facts of a file in an array, for a link itself.}
        description {Sets the elements of VAR as `file stat` does. For a link it gives the facts of the link, and not of its target.}
        returns {An empty string.}
        see {{file stat}}
        argument NAME {
            type path
            summary {The path.}
        }
        argument VAR {
            type {array name}
            summary {The array for the facts.}
        }
        example {
            set f [open n.txt w]; close $f
            file lstat n.txt st
            set st(type)
        } file
        error {file lstat nope.txt} {wrong # args: should be "file lstat name varName"} NONE
    }

    subcommand attributes {
        synopsis {file attributes NAME ?OPTION ?VALUE ...??}
        summary {Gives or sets the attributes of the platform of a file; not available in ztcl.}
        description {In Tcl, the attributes of the platform, such as `-permissions` on Unix or `-hidden` on Windows. In ztcl each call is an error.}
        returns {An error in ztcl.}
        see {{file stat}}
        difference {Tcl 8.6.16 and 9.0.4 have the attributes of the platform ([issue 687](https://github.com/beetlebugorg/ztcl/issues/687)).}
        argument NAME {
            type path
            summary {The path.}
        }
        example {
            set f [open n.txt w]; close $f
            catch {file attributes n.txt}
        } 1
        error {file attributes n.txt} {file attributes is not available} NONE
    }

    subcommand copy {
        synopsis {file copy ?-force? ?--? SOURCE TARGET}
        synopsis {file copy ?-force? ?--? SOURCE ?SOURCE ...? DIR}
        summary {Copies files and folders.}
        description {
            Copies SOURCE to TARGET. When TARGET is a folder, the copy goes into it with the name of SOURCE, and with more than one SOURCE the last argument must be a folder. A folder copies with all its content.

            A TARGET that exists is an error, unless `-force` is there. `--` ends the options, for a SOURCE that starts with `-`.
        }
        returns {An empty string.}
        see {{file rename} {file delete}}
        difference {Tcl 9.0.4 on Windows says `file exists` for a target that exists, with `-errorcode POSIX EEXIST {file exists}`. ztcl says `file already exists` as Tcl 8.6.16 does.}
        argument SOURCE {
            type path
            repeats
            summary {A file or a folder to copy.}
        }
        argument TARGET {
            type path
            summary {The new path, or a folder for the copies.}
        }
        example {
            set f [open n.txt w]; close $f
            file copy n.txt m.txt
            file exists m.txt
        } 1
        example {
            set f [open a.txt w]; close $f
            file mkdir dd
            file copy a.txt dd
            file exists dd/a.txt
        } 1
        example {
            file mkdir src/sub; set f [open src/sub/f w]; close $f
            file copy src dst
            file exists dst/sub/f
        } 1
        error {file copy nope.txt x.txt} {error copying "nope.txt": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {
            set f [open n2.txt w]; close $f
            file copy n2.txt m2.txt
            file copy n2.txt m2.txt
        } {error copying "n2.txt" to "m2.txt": file already exists} {POSIX EEXIST {file already exists}}
        error {file copy} {wrong # args: should be "file copy ?-option value ...? source ?source ...? target"} NONE
        option -force {
            type flag
            summary {Replaces a target that exists.}
            description {With `-force` a TARGET that exists is replaced by the copy.}
            example {
                set f [open p.txt w]; puts -nonewline $f hello; close $f
                set f [open q.txt w]; close $f
                file copy -force p.txt q.txt
                file size q.txt
            } 5
            error {file copy -bogus a b} {bad option "-bogus": must be -force or --} NONE
        }
        option -- {
            type flag
            summary {Ends the options.}
            description {The next argument is a SOURCE, also when it starts with `-`.}
            example {
                set f [open -x w]; close $f
                file copy -- -x y
                file exists y
            } 1
            noerrors {A flag has no value to check.}
        }
    }

    subcommand rename {
        synopsis {file rename ?-force? ?--? SOURCE TARGET}
        synopsis {file rename ?-force? ?--? SOURCE ?SOURCE ...? DIR}
        summary {Moves or renames files and folders.}
        description {Moves SOURCE to TARGET, with the rules of `file copy` for a folder as TARGET, more than one SOURCE, `-force`, and `--`. The SOURCE is gone after the move.}
        returns {An empty string.}
        see {{file copy} {file delete}}
        argument SOURCE {
            type path
            repeats
            summary {A file or a folder to move.}
        }
        argument TARGET {
            type path
            summary {The new path, or a folder for the moved files.}
        }
        example {
            set f [open m.txt w]; close $f
            file rename m.txt k.txt
            list [file exists m.txt] [file exists k.txt]
        } {0 1}
        example {
            set f [open s1 w]; close $f
            file mkdir dd
            file rename s1 dd
            file exists dd/s1
        } 1
        error {file rename nope.txt z.txt} {error renaming "nope.txt": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {file rename a} {wrong # args: should be "file rename ?-option value ...? source ?source ...? target"} NONE
        option -force {
            type flag
            summary {Replaces a target that exists.}
            description {With `-force` a TARGET that exists is replaced.}
            example {
                set f [open r1 w]; close $f
                set f [open r2 w]; close $f
                file rename -force r1 r2
                file exists r1
            } 0
            error {file rename -force} {wrong # args: should be "file rename ?-option value ...? source ?source ...? target"} NONE
        }
        option -- {
            type flag
            summary {Ends the options.}
            description {The next argument is a SOURCE, also when it starts with `-`.}
            example {
                set f [open -r w]; close $f
                file rename -- -r r
                file exists r
            } 1
            noerrors {A flag has no value to check.}
        }
    }

    subcommand delete {
        synopsis {file delete ?-force? ?--? ?NAME ...?}
        summary {Removes files and folders.}
        description {Removes each NAME. A NAME that does not exist is no error. A folder with content is an error, unless `-force` is there: then the folder goes away with all its content. With no NAME it removes no file.}
        returns {An empty string.}
        see {{file mkdir} {file rename}}
        argument NAME {
            type path
            optional
            repeats
            summary {A file or a folder to remove.}
        }
        example {
            set f [open n.txt w]; close $f
            file delete n.txt
            file exists n.txt
        } 0
        example {file delete nope.txt} {}
        error {
            file mkdir data/sub
            file delete data
        } {error deleting "data": directory not empty} {POSIX EEXIST {file already exists}}
        option -force {
            type flag
            summary {Removes a folder with all its content.}
            description {With `-force` a folder that has files goes away with each of them.}
            example {
                file mkdir data2/sub
                file delete -force data2
                file exists data2
            } 0
            noerrors {A flag has no value to check.}
        }
        option -- {
            type flag
            summary {Ends the options.}
            description {The next argument is a NAME, also when it starts with `-`.}
            example {file delete -- -x} {}
            noerrors {A flag has no value to check.}
        }
    }

    subcommand link {
        synopsis {file link ?-symbolic|-hard? LINK ?TARGET?}
        summary {Makes a link, or gives the target of a link; not available in ztcl.}
        description {In Tcl, makes LINK point at TARGET, or gives the target of LINK. In ztcl each call is an error.}
        returns {An error in ztcl.}
        see {{file readlink}}
        difference {Tcl 8.6.16 and 9.0.4 make links ([issue 687](https://github.com/beetlebugorg/ztcl/issues/687)).}
        argument LINK {
            type path
            summary {The path of the link.}
        }
        argument TARGET {
            type path
            optional
            summary {The path that the link points at.}
        }
        example {catch {file link -symbolic lnk n.txt}} 1
        error {file link -symbolic lnk n.txt} {could not link: links are not available in the root folder} {POSIX EACCES {permission denied}}
    }

    subcommand readlink {
        synopsis {file readlink NAME}
        summary {Gives the target of a symbolic link; not available in ztcl.}
        description {In Tcl, gives the path that the link NAME points at. In ztcl each call is an error.}
        returns {An error in ztcl.}
        see {{file link}}
        difference {Tcl 8.6.16 and 9.0.4 read links ([issue 687](https://github.com/beetlebugorg/ztcl/issues/687)).}
        argument NAME {
            type path
            summary {The path of the link.}
        }
        example {catch {file readlink n.txt}} 1
        error {file readlink n.txt} {could not readlink: links are not available in the root folder} {POSIX EACCES {permission denied}}
    }

    subcommand tempfile {
        synopsis {file tempfile ?VAR? ?TEMPLATE?}
        summary {Opens a new temporary file and gives its channel.}
        description {Makes a new empty file in the working folder, opens it for reading and writing, and gives its channel. With VAR it sets VAR to the absolute path of the file. ztcl names the file `tcl_tmpN` and does not use TEMPLATE. The file stays after `close`: delete it with `file delete`.}
        returns {The name of the channel.}
        see {open close {file delete}}
        difference {ztcl accepts more arguments than tclsh allows ([issue 688](https://github.com/beetlebugorg/ztcl/issues/688)).}
        argument VAR {
            type {variable name}
            optional
            summary {A variable for the path of the file.}
        }
        argument TEMPLATE {
            type path
            optional
            summary {A template of the name, which ztcl does not use.}
        }
        example {
            set f [file tempfile p]
            close $f
            list [file exists $p] [file pathtype $p]
        } {1 absolute}
        example {
            set f [file tempfile]
            set r [string match file* $f]
            close $f
            set r
        } 1
        noerrors {A call opens a new file. ztcl does not check the count of arguments of this subcommand (issue 688).}
    }

    subcommand channels {
        synopsis {file channels ?PATTERN?}
        summary {Gives the names of the open channels.}
        description {Gives the names of the channels of the interpreter, or the names that match the glob PATTERN. The same command is `chan names`.}
        returns {A list of channel names.}
        see {{chan names} open close}
        argument PATTERN {
            type {glob pattern}
            optional
            summary {A pattern for the names.}
        }
        example {lsort [file channels std*]} {stderr stdin stdout}
        error {file channels a b} {wrong # args: should be "file channels ?pattern?"} {TCL WRONGARGS}
    }

    subcommand system {
        synopsis {file system NAME}
        summary {Gives the file system of a path.}
        description {Gives a list of the kind of the file system and its name. In the root folder it is `native root` for each path. In host mode on Windows the name is the type of the volume, such as `native NTFS`.}
        returns {A list of two words.}
        see {{file volumes}}
        difference {Tcl 8.6.16 and 9.0.4 give an error for more than one argument ([issue 688](https://github.com/beetlebugorg/ztcl/issues/688)).}
        argument NAME {
            type path
            summary {The path.}
        }
        example {file system n.txt} {native root}
        noerrors {Each path gives a list of two words. ztcl does not check the count of arguments of this subcommand (issue 688).}
    }

    subcommand volumes {
        synopsis {file volumes}
        summary {Gives the volumes of the file system.}
        description {Gives the list of the volumes: the drives, such as `C:/ D:/`, in host mode on Windows, and `/` in the root folder and on Linux and macOS.}
        returns {A list of volumes.}
        see {{file system}}
        example {file volumes} /
        noerrors {Each call gives a list. ztcl does not check the count of arguments of this subcommand (issue 688).}
    }
}
