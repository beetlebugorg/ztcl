# The command reference: chan. The format is in
# docs/dev/reference-format.md.

command chan {
    area channels
    since 1.0.0-beta.1
    capability channels
    flags {--root . --allow channels,file,event}
    synopsis {chan SUBCOMMAND ?ARG ...?}
    summary {The commands for channels: read, write, move, configure, and copy.}
    description {
        The channel commands as one ensemble. A channel is a stream of bytes with a name, such as `stdout` or the result of `open`. Most subcommands work as the command of the same name: `chan gets` is `gets`, `chan configure` is `fconfigure`, and `chan copy` is `fcopy`.

        A new interpreter has no channels: the host turns on the capability `channels`, and `open` of a file also needs `file`. A file writes the line end of its platform by default, `\r\n` on Windows and `\n` elsewhere, as tclsh does, and its default encoding is UTF-8 on each platform. The examples of this page set `-translation lf` where a count of bytes depends on the line end.

        A unique prefix of a subcommand is the subcommand. The examples of this page run in an empty root folder, and most of them read the file `a.txt` with the one line `hello`.
    }
    returns {The result of the subcommand.}
    see {open close gets read puts fconfigure {file channels}}
    release {In Tcl 9.1 the messages of a wrong count of arguments name the channel `channel`, and in Tcl 8.6 `channelId`.}
    example {
        set f [open a.txt w]; chan puts $f hello; chan close $f
        set f [open a.txt]
        set line [chan gets $f]
        chan close $f
        set line
    } hello
    example {lsort [chan names std*]} {stderr stdin stdout}
    error {chan bogus} {unknown or ambiguous subcommand "bogus": must be blocked, close, configure, copy, create, eof, event, flush, gets, names, pending, pipe, pop, postevent, push, puts, read, seek, tell, or truncate} {TCL LOOKUP SUBCOMMAND bogus} -tcl 8.6
    error {chan bogus} {unknown or ambiguous subcommand "bogus": must be blocked, close, configure, copy, create, eof, event, flush, gets, isbinary, names, pending, pipe, pop, postevent, push, puts, read, seek, tell, or truncate} {TCL LOOKUP SUBCOMMAND bogus} -tcl 9.1
    error {chan p} {unknown or ambiguous subcommand "p": must be blocked, close, configure, copy, create, eof, event, flush, gets, names, pending, pipe, pop, postevent, push, puts, read, seek, tell, or truncate} {TCL LOOKUP SUBCOMMAND p} -tcl 8.6
    error {chan blocked} {wrong # args: should be "chan blocked channelId"} {TCL WRONGARGS} -tcl 8.6
    error {chan blocked} {wrong # args: should be "chan blocked channel"} {TCL WRONGARGS} -tcl 9.1
    error {chan close nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}

    subcommand puts {
        synopsis {chan puts ?-nonewline? ?CHAN? STRING}
        summary {Writes a string and a newline to a channel.}
        description {Writes STRING and a newline to CHAN, by default `stdout`. The bytes go to the buffer of the channel, and out with `chan flush`, `chan close`, or a full buffer. The channel must be open for writing.}
        returns {An empty string.}
        see {{chan flush} {chan gets} puts}
        argument CHAN {
            type channel
            optional
            default stdout
            summary {The channel to write to.}
        }
        argument STRING {
            type string
            summary {The text to write.}
        }
        example {
            set f [open a.txt w]; chan configure $f -translation lf; chan puts $f hello; chan close $f
            file size a.txt
        } 6
        example {chan puts stdout hi} {} -output "hi\n"
        error {
            set f [open b.txt w]; chan close $f
            set f [open b.txt]
            catch {chan puts $f x} m
            chan close $f
            error [regsub {file\d+} $m fileN]
        } {channel "fileN" wasn't opened for writing} NONE -note {The example puts fileN in place of the name of the channel, since the name changes from run to run.}
        error {chan puts} {wrong # args: should be "chan puts ?-nonewline? ?channelId? string"} {TCL WRONGARGS} -tcl 8.6
        error {chan puts} {wrong # args: should be "chan puts ?-nonewline? ?channel? string"} {TCL WRONGARGS} -tcl 9.1
        option -nonewline {
            type flag
            summary {Writes no newline after the string.}
            description {Writes STRING as it is, with no newline at its end.}
            example {
                set f [open n.txt w]; chan puts -nonewline $f x; chan close $f
                file size n.txt
            } 1
            noerrors {A flag has no value to check.}
        }
    }

    subcommand gets {
        synopsis {chan gets CHAN ?VAR?}
        summary {Reads one line from a channel.}
        description {Reads the next line of CHAN, with no newline at its end. With VAR it puts the line in VAR and gives its count of characters, or -1 at the end of the channel. With no VAR it gives the line, or an empty string at the end; use `chan eof` to tell an empty line from the end.}
        returns {The line, or with VAR the count of its characters or -1.}
        see {{chan read} {chan eof} gets}
        argument CHAN {
            type channel
            summary {The channel to read.}
        }
        argument VAR {
            type {variable name}
            optional
            summary {A variable for the line.}
        }
        example {
            set f [open a.txt w]; chan puts $f hello; chan close $f
            set f [open a.txt]
            set l [chan gets $f]
            chan close $f
            set l
        } hello
        example {
            set f [open a.txt]
            chan gets $f line
            set n [chan gets $f line2]
            chan close $f
            list $line $n
        } {hello -1}
        error {chan gets nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
    }

    subcommand read {
        synopsis {chan read ?-nonewline? CHAN}
        synopsis {chan read CHAN COUNT}
        summary {Reads the rest of a channel, or a count of characters.}
        description {Reads CHAN to its end and gives the text. With COUNT it reads at most COUNT characters. At the end of the channel the result is an empty string.}
        returns {The text that was read.}
        see {{chan gets} {chan seek} read}
        argument CHAN {
            type channel
            summary {The channel to read.}
        }
        argument COUNT {
            type {integer, 0 or more}
            optional
            summary {The most characters to read.}
        }
        example {
            set f [open a.txt w]; chan puts $f hello; chan close $f
            set f [open a.txt]
            set d [chan read $f 3]
            chan close $f
            set d
        } hel
        example {
            set f [open a.txt]
            set d [chan read $f]
            chan close $f
            set d
        } "hello\n"
        error {
            set f [open a.txt]
            catch {chan read $f x} m
            chan close $f
            error $m
        } {expected non-negative integer but got "x"} NONE
        option -nonewline {
            type flag
            summary {Drops the newline at the end of the text.}
            description {Reads to the end and drops one newline at the end of the text, when it has one.}
            example {
                set f [open a.txt]
                set d [chan read -nonewline $f]
                chan close $f
                set d
            } hello
            noerrors {A flag has no value to check.}
        }
    }

    subcommand eof {
        synopsis {chan eof CHAN}
        summary {Tests whether the last read reached the end of a channel.}
        description {Gives 1 when the last read of CHAN met the end of its data, else 0. A new channel gives 0 until a read meets the end.}
        returns {1 or 0.}
        see {{chan gets} {chan read} eof}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            set f [open a.txt w]; chan puts $f hello; chan close $f
            set f [open a.txt]
            chan read $f
            set e [chan eof $f]
            chan close $f
            set e
        } 1
        error {chan eof nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
    }

    subcommand seek {
        synopsis {chan seek CHAN OFFSET ?ORIGIN?}
        summary {Moves the place of the next read or write of a channel.}
        description {Moves the place of CHAN to OFFSET bytes from ORIGIN: `start` (the default), `current`, or `end`. A negative OFFSET moves back from `current` or `end`. A seek empties the buffers of the channel.}
        returns {An empty string.}
        see {{chan tell} seek}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        argument OFFSET {
            type integer
            summary {The count of bytes to move.}
        }
        argument ORIGIN {
            type {start, current, or end}
            optional
            default start
            values {start current end}
            summary {The place that OFFSET counts from.}
        }
        example {
            set f [open a.txt w]; chan configure $f -translation lf; chan puts $f hello; chan close $f
            set f [open a.txt]
            chan seek $f 2
            set d [chan read $f]
            chan close $f
            set d
        } "llo\n"
        example {
            set f [open a.txt]
            chan seek $f -2 end
            set d [chan read $f]
            chan close $f
            set d
        } "o\n"
        error {
            set f [open a.txt]
            catch {chan seek $f x} m
            chan close $f
            error $m
        } {expected integer but got "x"} NONE
    }

    subcommand tell {
        synopsis {chan tell CHAN}
        summary {Gives the place of the next read or write of a channel.}
        description {Gives the place of CHAN in bytes from its start, or -1 for a channel with no place, such as a pipe.}
        returns {An integer.}
        see {{chan seek} tell}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            set f [open a.txt w]; chan puts $f hello; chan close $f
            set f [open a.txt]
            chan read $f 2
            set t [chan tell $f]
            chan close $f
            set t
        } 2
        error {chan tell nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
    }

    subcommand create {
        synopsis {chan create MODE CMDPREFIX}
        summary {Makes a channel whose driver is a Tcl command.}
        description {
            Makes a reflected channel with the name `rcN` and gives the name. MODE is a list of `read` and `write`. Each operation of the channel calls CMDPREFIX with the name of a method, the name of the channel, and the arguments of the method:

            - `initialize CHAN MODE` gives the list of the methods of the handler. `initialize`, `finalize`, and `watch` are required, `read` for the mode `read`, and `write` for the mode `write`. `cget` and `cgetall` come as a pair.
            - `finalize CHAN` runs at the close. Its error is the error of `close`.
            - `read CHAN COUNT` gives at most COUNT bytes, and an empty string at the end of the data.
            - `write CHAN BYTES` gives the count of the bytes that it wrote, 1 or more. The channel calls it again with the rest.
            - `seek CHAN OFFSET BASE` gives the new place, for `seek` and `tell`. BASE is `start`, `current`, or `end`.
            - `watch CHAN EVENTS` gets the events with a handler, a list of `read` and `write`, each time the list changes.
            - `configure CHAN OPTION VALUE`, `cget CHAN OPTION`, and `cgetall CHAN` handle the options that are not standard options of `fconfigure`.
            - `blocking CHAN MODE` gets 0 or 1 at a change of `-blocking`.

            The buffers, the encoding, and the translation of the channel work as for each other channel. The events of the channel come from `chan postevent`. A `read` that fails with `EAGAIN` is an error: tclsh reads it as a channel with no data yet.
        }
        returns {The name of the channel.}
        see {{chan postevent} {chan configure}}
        argument MODE {
            type {list of read and write}
            summary {The directions of the channel.}
        }
        argument CMDPREFIX {
            type {command prefix}
            summary {The handler of the channel.}
        }
        example {
            proc drv {cmd c args} {
                switch $cmd {
                    initialize {return {initialize finalize watch read}}
                    read {
                        set n [lindex $args 0]
                        set d [string range $::data 0 [expr {$n - 1}]]
                        set ::data [string range $::data $n end]
                        return $d
                    }
                }
            }
            set ::data "one\ntwo\n"
            set c [chan create read drv]
            set r [list [chan gets $c] [chan read $c] [chan eof $c]]
            chan close $c
            set r
        } {one {two
} 1}
        example {
            proc out {cmd c args} {
                switch $cmd {
                    initialize {return {initialize finalize watch write}}
                    write {append ::out [lindex $args 0]; return [string length [lindex $args 0]]}
                }
            }
            set ::out ""
            set c [chan create write out]
            chan puts -nonewline $c hello
            chan close $c
            set ::out
        } hello
        error {
            proc d2 {cmd c args} {if {$cmd eq "initialize"} {return {initialize finalize watch}}}
            chan create read d2
        } {chan handler "d2" lacks a "read" method} NONE
        error {
            proc d3 {cmd c args} {if {$cmd eq "initialize"} {return {finalize watch read}}}
            chan create read d3
        } {chan handler "d3" does not support all required methods} NONE
        error {
            proc d1 {cmd c args} {if {$cmd eq "initialize"} {return {initialize finalize watch read bogus}}}
            chan create read d1
        } {chan handler "d1 initialize" returned bad method "bogus": must be blocking, cget, cgetall, configure, finalize, initialize, read, seek, watch, or write} {TCL LOOKUP INDEX method bogus}
        error {chan create bogus x} {bad mode "bogus": must be read or write} {TCL LOOKUP INDEX mode bogus}
        error {chan create} {wrong # args: should be "chan create mode cmdprefix"} {TCL WRONGARGS}
    }

    subcommand push {
        synopsis {chan push CHAN CMDPREFIX}
        summary {Puts a transform on top of a channel.}
        description {
            Puts a transform with a handle `rtN` on top of CHAN and gives the name of CHAN. Each read and each write of the channel goes through the transform, and through the transforms below it. CMDPREFIX gets the name of a method, the handle, and the arguments of the method:

            - `initialize HANDLE MODE` gives the list of the methods. `initialize` and `finalize` are required, and the transform needs `read` for a channel that reads or `write` for a channel that writes.
            - `read HANDLE BYTES` gets the bytes from below and gives the bytes for the channel.
            - `write HANDLE BYTES` gets the bytes of the channel and gives the bytes to write below.
            - `drain HANDLE` gives the last bytes for the channel at the end of the data below.
            - `flush HANDLE` gives the last bytes to write below, at the close and at `chan pop`.
            - `clear HANDLE` runs at `seek`. The transform drops the bytes that it holds.
            - `finalize HANDLE` runs at the close and at `chan pop`.

            The output of the channel before `push` goes below the transform. A read waits for data also on a channel with `-blocking 0`. An error of `read` is an error of the read of the channel: tclsh 8.6.16 gives the end of the data. `limit?` is accepted and not called.
        }
        returns {The name of the channel.}
        see {{chan pop} {chan create}}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        argument CMDPREFIX {
            type {command prefix}
            summary {The handler of the transform.}
        }
        example {
            proc up {cmd h args} {
                switch $cmd {
                    initialize {return {initialize finalize read write}}
                    read - write {return [string toupper [lindex $args 0]]}
                }
            }
            set f [open a.txt w]
            chan push $f up
            chan puts -nonewline $f hello
            chan close $f
            set f [open a.txt]
            set r [chan read $f]
            chan close $f
            set r
        } HELLO
        error {
            proc b2 {cmd h args} {if {$cmd eq "initialize"} {return {initialize finalize}}}
            set f [open a.txt w]
            catch {chan push $f b2} m
            chan close $f
            error $m
        } {chan handler "b2" makes the channel inaccessible} NONE
        error {
            proc b1 {cmd h args} {if {$cmd eq "initialize"} {return {initialize finalize watch}}}
            set f [open a.txt w]
            catch {chan push $f b1} m o
            chan close $f
            error $m {} [dict get $o -errorcode]
        } {chan handler "b1 initialize" returned bad method "watch": must be clear, drain, finalize, flush, initialize, limit?, read, or write} {TCL LOOKUP INDEX method watch}
        error {chan push nochan up} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
        error {chan push} {wrong # args: should be "chan push channel cmdprefix"} {TCL WRONGARGS}
    }

    subcommand pop {
        synopsis {chan pop CHAN}
        summary {Takes the top transform off a channel.}
        description {Writes the output of the channel through the top transform and calls its `flush` and `finalize`. The bytes that the transform holds, and the result of its `drain`, go to the read buffer of the channel. A channel with no transform stays as it is.}
        returns {An empty string.}
        see {{chan push}}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            proc up {cmd h args} {
                switch $cmd {
                    initialize {return {initialize finalize write}}
                    write {return [string toupper [lindex $args 0]]}
                }
            }
            set f [open a.txt w]
            chan push $f up
            chan puts -nonewline $f ab
            chan pop $f
            chan puts -nonewline $f cd
            chan close $f
            set f [open a.txt]
            set r [chan read $f]
            chan close $f
            set r
        } ABcd
        example {chan pop stdin} {}
        error {chan pop} {wrong # args: should be "chan pop channel"} {TCL WRONGARGS}
    }

    subcommand postevent {
        synopsis {chan postevent CHAN EVENTS}
        summary {Posts events of a reflected channel to the event loop.}
        description {Posts the events of the list EVENTS, `read` and `write`, for the reflected channel CHAN of `chan create`. The next pass of the event loop runs the handler of `chan event` for each event. Each event must be in the last `watch` of the channel.}
        returns {An empty string.}
        see {{chan create} {chan event}}
        argument CHAN {
            type channel
            summary {A channel of `chan create`.}
        }
        argument EVENTS {
            type {list of read and write}
            summary {The events.}
        }
        example {
            proc drv {cmd c args} {if {$cmd eq "initialize"} {return {initialize finalize watch read}}}
            set c [chan create read drv]
            chan event $c readable {set ::fired 1}
            chan postevent $c read
            update
            chan close $c
            set ::fired
        } 1
        error {
            proc drv {cmd c args} {if {$cmd eq "initialize"} {return {initialize finalize watch read}}}
            set c [chan create read drv]
            catch {chan postevent $c read} m
            chan close $c
            error [string map [list $c rcN] $m]
        } {tried to post events channel "rcN" is not interested in} NONE
        error {chan postevent stdout read} {can not find reflected channel named "stdout"} {TCL LOOKUP CHANNEL stdout}
        error {chan postevent} {wrong # args: should be "chan postevent channel eventspec"} {TCL WRONGARGS}
    }

    subcommand truncate {
        synopsis {chan truncate CHAN ?LENGTH?}
        summary {Sets the size of a file of a channel.}
        description {Writes the buffered output of CHAN, then sets the size of its file to LENGTH bytes, or to the current place of the channel. The place of the channel stays. A channel that is no file, such as a pipe, gives `EINVAL`.}
        returns {An empty string.}
        see {{chan seek} {chan tell} {file size}}
        argument CHAN {
            type channel
            summary {A channel of a file open for writing.}
        }
        argument LENGTH {
            type integer
            optional
            summary {The new size in bytes, 0 or more.}
        }
        example {
            set f [open a.txt w]; chan puts -nonewline $f 0123456789
            chan truncate $f 4
            chan close $f
            file size a.txt
        } 4
        example {
            set f [open a.txt w]; chan puts -nonewline $f 0123456789; chan close $f
            set f [open a.txt r+]
            chan seek $f 2
            chan truncate $f
            chan close $f
            file size a.txt
        } 2
        error {
            set f [open a.txt w]
            catch {chan truncate $f -1} m
            chan close $f
            error $m
        } {cannot truncate to negative length of file} NONE
        error {chan truncate nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
        error {chan truncate} {wrong # args: should be "chan truncate channelId ?length?"} {TCL WRONGARGS} -tcl 8.6
    }

    subcommand isbinary {
        synopsis {chan isbinary CHAN}
        tcl 9.1
        summary {Tests whether a channel passes its bytes with no change.}
        description {Gives 1 when CHAN has the encoding `binary`, the translation `lf` for input and output, and no `-eofchar`, else 0. `fconfigure $f -translation binary` makes such a channel.}
        returns {1 or 0.}
        see {{chan configure}}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            set f [open a.txt w]
            set r [list [chan isbinary $f]]
            chan configure $f -translation binary
            lappend r [chan isbinary $f]
            chan close $f
            set r
        } {0 1}
        error {chan isbinary nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
        error {chan isbinary} {wrong # args: should be "chan isbinary channel"} {TCL WRONGARGS}
    }

    subcommand flush {
        synopsis {chan flush CHAN}
        summary {Writes the buffered output of a channel.}
        description {Writes each byte in the output buffer of CHAN to its file or device. A channel with no buffered output stays as it is.}
        returns {An empty string.}
        see {{chan puts} {chan configure} flush}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            set f [open b.txt w]
            chan puts -nonewline $f x
            chan flush $f
            set s [file size b.txt]
            chan close $f
            set s
        } 1
        error {chan flush nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
    }

    subcommand close {
        synopsis {chan close CHAN ?DIRECTION?}
        summary {Closes a channel, or one direction of it.}
        description {Writes the buffered output of CHAN and closes it, and its name goes away. With DIRECTION `read` or `write` it closes only that side of a channel that has both, such as a socket.}
        returns {An empty string.}
        see {{chan names} close open}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        argument DIRECTION {
            type {read or write}
            optional
            values {read write}
            summary {The side to close.}
        }
        example {
            set f [open a.txt w]
            chan close $f
            expr {$f in [chan names]}
        } 0
        example {
            set f [open a.txt]
            chan close $f read
        } {}
        error {
            set f [open a.txt]
            catch {chan close $f bogus} m
            chan close $f
            error $m
        } {bad direction "bogus": must be read or write} NONE
        error {chan close} {wrong # args: should be "chan close channelId ?direction?"} {TCL WRONGARGS} -tcl 8.6
        error {chan close} {wrong # args: should be "chan close channel ?direction?"} {TCL WRONGARGS} -tcl 9.1
    }

    subcommand names {
        synopsis {chan names ?PATTERN?}
        summary {Gives the names of the open channels.}
        description {Gives the names of the channels of the interpreter, or the names that match the glob PATTERN, in no fixed order.}
        returns {A list of channel names.}
        see {{file channels} open}
        argument PATTERN {
            type {glob pattern}
            optional
            summary {A pattern for the names.}
        }
        example {lsort [chan names std*]} {stderr stdin stdout}
        example {chan names nomatch*} {}
        noerrors {Each PATTERN is valid, and a pattern with no match gives an empty list.}
    }

    subcommand configure {
        synopsis {chan configure CHAN}
        synopsis {chan configure CHAN OPTION}
        synopsis {chan configure CHAN OPTION VALUE ?OPTION VALUE ...?}
        summary {Gives or sets the options of a channel.}
        description {With no OPTION it gives a list of each option of CHAN and its value. With one OPTION it gives its value. With pairs of options and values it sets each one, in order. The options are the ones below, and a socket or a serial port has more.}
        returns {The list of options and values, one value, or an empty string.}
        see {fconfigure {chan copy}}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            set f [open a.txt w]; chan close $f
            set f [open a.txt]
            set r [lsort [dict keys [chan configure $f]]]
            chan close $f
            set r
        } {-blocking -buffering -buffersize -encoding -eofchar -translation} -tcl 8.6
        example {
            set f [open a.txt w]; chan close $f
            set f [open a.txt]
            set r [lsort [dict keys [chan configure $f]]]
            chan close $f
            set r
        } {-blocking -buffering -buffersize -encoding -eofchar -profile -translation} -tcl 9.1
        error {chan configure nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
        option -blocking {
            value BOOLEAN
            type boolean
            default 1
            summary {Whether a read or a write waits for its data.}
            description {With 0, a read gives what is there and a write does not wait; use it with `chan event`.}
            example {
                set f [open a.txt]
                chan configure $f -blocking 0
                set r [chan configure $f -blocking]
                chan close $f
                set r
            } 0
            noerrors {Each boolean is valid.}
        }
        option -buffering {
            value MODE
            type {full, line, or none}
            default full
            values {full line none}
            summary {When the output buffer goes out.}
            description {`full` writes when the buffer is full, `line` after each newline, and `none` at once.}
            example {
                set f [open a.txt]
                chan configure $f -buffering none
                set r [chan configure $f -buffering]
                chan close $f
                set r
            } none
            error {
                set f [open a.txt]
                catch {chan configure $f -buffering bogus} m
                chan close $f
                error $m
            } {bad value for -buffering: must be one of full, line, or none} NONE
        }
        option -buffersize {
            value SIZE
            type integer
            summary {The size of the buffers in bytes.}
            description {The size of the input and output buffers of the channel.}
            example {
                set f [open a.txt]
                chan configure $f -buffersize 100
                set r [chan configure $f -buffersize]
                chan close $f
                set r
            } 100
            noerrors {ztcl keeps each size it gets.}
        }
        option -encoding {
            value NAME
            type {encoding name}
            default utf-8
            summary {The encoding of the text of the channel.}
            description {The encoding between the characters of the script and the bytes of the channel. A file has `utf-8` by default on each platform. `binary` is no encoding: one byte for each character.}
            example {
                set f [open a.txt]
                set c [chan configure $f -encoding]
                chan close $f
                set c
            } utf-8
            error {
                set f [open a.txt]
                catch {chan configure $f -encoding bogus} m
                chan close $f
                error $m
            } {unknown encoding "bogus"} NONE
        }
        option -eofchar {
            value CHAR
            type character
            default {}
            summary {A character that ends the input.}
            description {A read stops at this character as at the end of the channel. The default is none.}
            example {
                set f [open a.txt]
                set r [chan configure $f -eofchar]
                chan close $f
                set r
            } {}
            noerrors {ztcl keeps each value it gets.}
        }
        option -translation {
            value MODE
            type {auto, binary, cr, crlf, or lf}
            default {auto for input; for output, crlf on Windows and lf elsewhere}
            values {auto binary cr crlf lf}
            summary {How the ends of lines change between the channel and the script.}
            description {On input, `auto` reads `\n`, `\r\n`, and `\r` as a newline. On output, `lf` writes `\n`, `crlf` writes `\r\n`, and `cr` writes `\r`, and a file writes the line end of its platform by default. `binary` changes no byte and sets the encoding to `binary`.}
            example {
                set f [open a.txt w]
                chan configure $f -translation crlf
                chan puts $f a
                chan close $f
                file size a.txt
            } 3
            example {
                set f [open b.bin w]
                chan configure $f -translation binary
                chan puts $f a
                chan close $f
                file size b.bin
            } 2
            error {
                set f [open a.txt]
                catch {chan configure $f -bogus 1} m
                chan close $f
                error $m
            } {bad option "-bogus": should be one of -blocking, -buffering, -buffersize, -encoding, -eofchar, or -translation} NONE -tcl 8.6
        }
        option -profile {
            value PROFILE
            type {strict, replace, or tcl8}
            tcl 9.1
            summary {What a read or a write does with a byte that the encoding cannot read.}
            description {`strict` makes such a byte an error, `replace` puts a replacement character in its place, and `tcl8` reads it as Tcl 8.6 does.}
            example {
                set f [open a.txt]
                chan configure $f -profile strict
                set r [chan configure $f -profile]
                chan close $f
                set r
            } strict
            error {
                set f [open a.txt]
                catch {chan configure $f -bogus 1} m
                chan close $f
                error $m
            } {bad option "-bogus": should be one of -blocking, -buffering, -buffersize, -encoding, -eofchar, -profile, or -translation} NONE
        }
    }

    subcommand copy {
        synopsis {chan copy IN OUT ?-size SIZE? ?-command SCRIPT?}
        summary {Copies the data of one channel to another.}
        description {Reads IN to its end, or SIZE bytes, and writes the data to OUT. With no `-command` it waits for the end and gives the count of bytes. With `-command` it copies in the background and calls SCRIPT with the count when it ends, which needs the event loop.}
        returns {The count of bytes, or an empty string with `-command`.}
        see {fcopy {chan read} {chan puts}}
        argument IN {
            type channel
            summary {The channel to read.}
        }
        argument OUT {
            type channel
            summary {The channel to write.}
        }
        example {
            set f [open a.txt w]; chan configure $f -translation lf; chan puts $f hello; chan close $f
            set in [open a.txt]; set out [open c.txt w]; chan configure $out -translation lf
            set n [chan copy $in $out]
            chan close $in; chan close $out
            list $n [file size c.txt]
        } {6 6}
        error {chan copy nochan stdout} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
        error {
            set in [open a.txt]
            catch {chan copy $in stdout -bogus 1} m
            chan close $in
            error $m
        } {bad option "-bogus": should be -size or -command} NONE
        option -size {
            value SIZE
            type integer
            default {-1, no limit}
            summary {The most bytes to copy.}
            description {Copies at most SIZE bytes. A negative SIZE copies to the end of IN.}
            example {
                set in [open a.txt]; set out [open c2.txt w]
                set n [chan copy $in $out -size 3]
                chan close $in; chan close $out
                list $n [file size c2.txt]
            } {3 3}
            error {
                set in [open a.txt]
                catch {chan copy $in stdout -size x} m
                chan close $in
                error $m
            } {expected integer but got "x"} NONE
        }
        option -command {
            value SCRIPT
            type {command prefix}
            summary {Copies in the background and calls a script at the end.}
            description {The copy runs in the event loop, and at its end the event loop calls SCRIPT with the count of bytes, and an error message as a second argument when the copy failed.}
            example {
                set in [open a.txt]; set out [open d.txt w]; chan configure $out -translation lf
                chan copy $in $out -command {set ::done}
                vwait ::done
                chan close $in; chan close $out
                list $::done [file size d.txt]
            } {6 6}
            noerrors {Each script is valid, and an error of SCRIPT goes to the handler of background errors.}
        }
    }

    subcommand pipe {
        synopsis {chan pipe}
        summary {Makes a pipe and gives its two channels.}
        description {Gives a list of two channels: the bytes that go into the second one come out of the first one. Close the second one to end the data of the first one.}
        returns {A list of the read channel and the write channel.}
        see {open exec {chan close}}
        example {
            lassign [chan pipe] r w
            chan puts $w hi; chan flush $w
            set l [chan gets $r]
            chan close $w; chan close $r
            set l
        } hi
        error {chan pipe x} {wrong # args: should be "chan pipe "} {TCL WRONGARGS}
    }

    subcommand pending {
        synopsis {chan pending MODE CHAN}
        summary {Gives the count of bytes that wait in a buffer of a channel.}
        description {With MODE `input` it gives the count of bytes of the input buffer that no read took yet, and with `output` the count of the output buffer, or -1 when the channel is not open for that side.}
        returns {An integer.}
        see {{chan configure} {chan blocked}}
        argument MODE {
            type {input or output}
            values {input output}
            summary {The buffer.}
        }
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            set f [open a.txt w]; chan close $f
            set f [open a.txt]
            set r [chan pending output $f]
            chan close $f
            set r
        } -1
        error {chan pending bogus stdin} {bad mode "bogus": must be input or output} {TCL LOOKUP INDEX mode}
    }

    subcommand blocked {
        synopsis {chan blocked CHAN}
        summary {Tests whether the last read of a channel stopped for want of data.}
        description {Gives 1 when the last read of a channel with `-blocking 0` had too few data, else 0.}
        returns {1 or 0.}
        see {{chan configure} fblocked}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        example {
            set f [open a.txt w]; chan close $f
            set f [open a.txt]
            set r [chan blocked $f]
            chan close $f
            set r
        } 0
        error {chan blocked nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
    }

    subcommand event {
        synopsis {chan event CHAN EVENT ?SCRIPT?}
        summary {Gives or sets the script that the event loop runs when a channel can be read or written.}
        description {With SCRIPT it sets the script for EVENT, `readable` or `writable`, of CHAN, and an empty SCRIPT removes it. With no SCRIPT it gives the script, or an empty string. The script runs in the event loop.}
        returns {The script, or an empty string.}
        see {fileevent vwait {chan configure}}
        argument CHAN {
            type channel
            summary {The channel.}
        }
        argument EVENT {
            type {readable or writable}
            values {readable writable}
            summary {The event.}
        }
        argument SCRIPT {
            type script
            optional
            summary {The script for the event.}
        }
        example {
            set f [open a.txt w]; chan close $f
            set f [open a.txt]
            chan event $f readable {set x 1}
            set r [chan event $f readable]
            chan close $f
            set r
        } {set x 1}
        error {chan event stdin bogus} {bad event name "bogus": must be readable or writable} {TCL LOOKUP INDEX {event name}}
    }
}
