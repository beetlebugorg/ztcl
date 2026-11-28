# Converted by tools/refdoc.tcl convert from channels.txt.

command chan {
    area channels
    since TODO
    synopsis {chan subcommand ?arg ...?}
    summary {The channel commands as one ensemble.}
    description {The channel commands as one ensemble. Each subcommand works as the command of the same name.}
    capability {channels}
    difference {Windows has no `chan pipe` in this version. `chan pending`, `chan push`, and the other subcommands of Tcl 8.6 that are not in the list are not in ztcl in this version.}
    subcommand close {
        synopsis {chan close CHAN ?DIRECTION?}
        summary {As `close`.}
        description {As `close`.}
    }
    subcommand configure {
        synopsis {chan configure CHAN ?-option value ...?}
        summary {As `fconfigure`.}
        description {As `fconfigure`.}
    }
    subcommand copy {
        synopsis {chan copy IN OUT ?-size N? ?-command CB?}
        summary {As `fcopy`.}
        description {As `fcopy`.}
    }
    subcommand eof {
        synopsis {chan eof CHAN}
        summary {As `eof`.}
        description {As `eof`.}
    }
    subcommand flush {
        synopsis {chan flush CHAN}
        summary {As `flush`.}
        description {As `flush`.}
    }
    subcommand gets {
        synopsis {chan gets CHAN ?VAR?}
        summary {As `gets`.}
        description {As `gets`.}
    }
    subcommand names {
        synopsis {chan names ?PATTERN?}
        summary {The names of the open channels.}
        description {The names of the open channels.}
    }
    subcommand pipe {
        synopsis {chan pipe}
        summary {Makes a pipe and gives two channels: the bytes that go into the second come out of the first.}
        description {Makes a pipe and gives two channels: the bytes that go into the second come out of the first. Linux and macOS have it, and the shell of the site has it in memory.}
    }
    subcommand puts {
        synopsis {chan puts ?-nonewline? ?CHAN? STRING}
        summary {As `puts`.}
        description {As `puts`.}
    }
    subcommand read {
        synopsis {chan read ?-nonewline? CHAN ?N?}
        summary {As `read`.}
        description {As `read`.}
    }
    subcommand seek {
        synopsis {chan seek CHAN OFFSET ?ORIGIN?}
        summary {As `seek`.}
        description {As `seek`.}
    }
    subcommand tell {
        synopsis {chan tell CHAN}
        summary {As `tell`.}
        description {As `tell`.}
    }
}
