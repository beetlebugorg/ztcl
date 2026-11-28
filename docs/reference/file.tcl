# Converted by tools/refdoc.tcl convert from channels.txt.

command file {
    area channels
    since TODO
    synopsis {file subcommand ?arg ...?}
    summary {Commands for paths and files.}
    description {Commands for paths and files. The name commands (`join`, `split`, `dirname`, `tail`, `extension`, `rootname`) work on text. The others read the file system, inside the root folder of the interpreter.}
    capability {file}
    flags {--root . --allow channels,file}
    example {file join notes 2026 a.json} notes/2026/a.json
    example {file extension notes.json} .json
    example {file mkdir data; file isdirectory data} 1
    subcommand join {
        synopsis {file join NAME ?NAME ...?}
        summary {One path from parts.}
        description {One path from parts.}
    }
    subcommand split {
        synopsis {file split NAME}
        summary {The parts of a path.}
        description {The parts of a path.}
    }
    subcommand dirname {
        synopsis {file dirname NAME}
        summary {The path without its last part.}
        description {The path without its last part.}
    }
    subcommand tail {
        synopsis {file tail NAME}
        summary {The last part.}
        description {The last part.}
    }
    subcommand extension {
        synopsis {file extension NAME}
        summary {The extension with its dot, such as `.json`.}
        description {The extension with its dot, such as `.json`.}
    }
    subcommand rootname {
        synopsis {file rootname NAME}
        summary {The path without its extension.}
        description {The path without its extension.}
    }
    subcommand normalize {
        synopsis {file normalize NAME}
        summary {The full path with `.` and `..` removed.}
        description {The full path with `.` and `..` removed.}
    }
    subcommand pathtype {
        synopsis {file pathtype NAME}
        summary {`absolute`, `relative`, or `volumerelative`.}
        description {`absolute`, `relative`, or `volumerelative`.}
    }
    subcommand nativename {
        synopsis {file nativename NAME}
        summary {The path with the separator of the platform.}
        description {The path with the separator of the platform.}
    }
    subcommand separator {
        synopsis {file separator ?NAME?}
        summary {The separator of paths.}
        description {The separator of paths.}
    }
    subcommand exists {
        synopsis {file exists NAME}
        summary {1 when the file exists.}
        description {1 when the file exists.}
    }
    subcommand isfile {
        synopsis {file isfile NAME}
        summary {1 for a file.}
        description {1 for a file.}
    }
    subcommand isdirectory {
        synopsis {file isdirectory NAME}
        summary {1 for a folder.}
        description {1 for a folder.}
    }
    subcommand readable {
        synopsis {file readable NAME}
        summary {1 when the file can be read.}
        description {1 when the file can be read.}
    }
    subcommand writable {
        synopsis {file writable NAME}
        summary {1 when the file can be written.}
        description {1 when the file can be written.}
    }
    subcommand executable {
        synopsis {file executable NAME}
        summary {1 when the file can run.}
        description {1 when the file can run.}
    }
    subcommand owned {
        synopsis {file owned NAME}
        summary {1 when the user owns the file.}
        description {1 when the user owns the file.}
    }
    subcommand size {
        synopsis {file size NAME}
        summary {The size in bytes.}
        description {The size in bytes.}
    }
    subcommand mtime {
        synopsis {file mtime NAME ?TIME?}
        summary {The time of the last change, in seconds.}
        description {The time of the last change, in seconds.}
    }
    subcommand atime {
        synopsis {file atime NAME ?TIME?}
        summary {The time of the last read, in seconds.}
        description {The time of the last read, in seconds.}
    }
    subcommand stat {
        synopsis {file stat NAME VAR}
        summary {Puts the facts of the file in an array.}
        description {Puts the facts of the file in an array.}
    }
    subcommand lstat {
        synopsis {file lstat NAME VAR}
        summary {As `stat`, for a link itself.}
        description {As `stat`, for a link itself.}
    }
    subcommand type {
        synopsis {file type NAME}
        summary {`file`, `directory`, `link`, and others.}
        description {`file`, `directory`, `link`, and others.}
    }
    subcommand attributes {
        synopsis {file attributes NAME ?OPTION ?VALUE ...??}
        summary {The attributes of the platform, such as `-permissions`.}
        description {The attributes of the platform, such as `-permissions`.}
    }
    subcommand mkdir {
        synopsis {file mkdir ?DIR ...?}
        summary {Makes folders, with each missing parent.}
        description {Makes folders, with each missing parent.}
    }
    subcommand copy {
        synopsis {file copy ?-force? ?--? SOURCE ?SOURCE ...? TARGET}
        summary {Copies files and folders.}
        description {Copies files and folders.}
    }
    subcommand rename {
        synopsis {file rename ?-force? ?--? SOURCE ?SOURCE ...? TARGET}
        summary {Moves files and folders.}
        description {Moves files and folders.}
    }
    subcommand delete {
        synopsis {file delete ?-force? ?--? ?NAME ...?}
        summary {Removes files, and folders with `-force`.}
        description {Removes files, and folders with `-force`.}
    }
    subcommand link {
        synopsis {file link ?-symbolic|-hard? LINK ?TARGET?}
        summary {Makes a link, or gives its target.}
        description {Makes a link, or gives its target.}
    }
    subcommand readlink {
        synopsis {file readlink NAME}
        summary {The target of a symbolic link.}
        description {The target of a symbolic link.}
    }
    subcommand tempfile {
        synopsis {file tempfile ?VAR? ?TEMPLATE?}
        summary {Opens a new temporary file and gives its channel.}
        description {Opens a new temporary file and gives its channel.}
    }
    subcommand channels {
        synopsis {file channels ?PATTERN?}
        summary {The names of the open channels.}
        description {The names of the open channels.}
    }
    subcommand system {
        synopsis {file system NAME}
        summary {The file system of a path.}
        description {The file system of a path.}
    }
    subcommand volumes {
        synopsis {file volumes}
        summary {The volumes, such as `/`.}
        description {The volumes, such as `/`.}
    }
}
