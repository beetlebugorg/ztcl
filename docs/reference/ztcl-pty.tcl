# The command reference: ztcl::pty. The format is in
# docs/dev/reference-format.md.

command ztcl::pty {
    area ztcl
    since 1.0.0-beta.1
    capability exec
    flags {--allow exec,channels,file,event}
    setup {
        # The shell of the platform: in host mode the separator of Windows is a backslash.
        set sh [expr {[file separator] eq "/" ? "/bin/sh" : "cmd.exe"}]
        # Reads the output with no block until the program ends, and gives its status.
        proc finish {t} {
            fconfigure $t -blocking 0
            for {set n 0} {[ztcl::pty status $t] eq "running" && $n < 1000} {incr n} { read $t; after 10 }
            ztcl::pty status $t
        }
    }
    synopsis {ztcl::pty SUBCOMMAND ?ARG ...?}
    summary {Runs a program in a pseudo terminal, for ztcl::vt and for tests of terminal apps.}
    description {
        Runs a program on a pseudo terminal (PTY): the program sees a terminal on its input and output, and the script reads and writes the other side as a channel. A terminal widget uses it to run a shell or a full-screen program, and `ztcl::vt` reads its output as a screen.

        The command exists only with the capability `exec`, and the reads and writes of its channel need `channels`, as for `open "|cmd"`. The program goes through the checks of `exec`: the `PATH` of `exec_host.env`, the allowlist `exec_host.allow`, and `exec_host.allow_root`, and `exec_host.timeout_ms` ends a program that runs too long. The program runs outside the root folder and outside each limit of the interpreter, with the full power of the user: it is not sandboxed. `ztcl::pty` does not exist on WebAssembly or on arm64 Windows, which have no `exec`.

        On Linux the terminal is `/dev/ptmx` and the program joins the cgroup of `exec`; on macOS it is `posix_openpt` with the process group of `exec`; on Windows it is ConPTY with the Job Object of `exec`. On Windows the console renders the program and sends VT escape sequences, so the output has cursor moves and colors also for plain text. On Linux and macOS the end of the program gives the end of the file on the channel.

        A subcommand has no short form, and an unknown subcommand gives `bad option` with `-errorcode NONE` ([issue 720](https://github.com/beetlebugorg/ztcl/issues/720)); the other errors of the module also have `-errorcode NONE`. Each command is one compute unit. The setup of the examples picks `/bin/sh`, or `cmd.exe` on Windows, and makes the proc `finish`, which reads with no block until the program ends: on Windows a blocking read keeps the process from its exit ([issue 728](https://github.com/beetlebugorg/ztcl/issues/728)).
    }
    returns {The result of the subcommand.}
    page modules/pty/
    see {exec open ztcl::vt}
    example {
        set t [ztcl::pty spawn -size {100 30} $sh]
        puts -nonewline $t "exit 4\r"
        set s [finish $t]
        close $t
        set s
    } {exit 4}
    error {ztcl::pty bogus} {bad option "bogus": must be kill, resize, size, spawn, or status} NONE
    error {ztcl::pty s} {bad option "s": must be kill, resize, size, spawn, or status} NONE
    error {ztcl::pty} {wrong # args: should be "ztcl::pty spawn|resize|size|status|kill ?arg ...?"} {TCL WRONGARGS}

    subcommand spawn {
        synopsis {ztcl::pty spawn ?-size {COLS ROWS}? ?-cwd DIR? ?-env {NAME VALUE ...}? ?--? PROGRAM ?ARG ...?}
        summary {Starts a program on a new pseudo terminal and gives a channel.}
        description {Starts PROGRAM with its arguments on a new PTY and gives a channel such as `pty3`. The channel is readable and writable, binary, and has no buffering, and `fileevent` and `fconfigure -blocking 0` work on it as on a pipe. The program runs directly from its argument list, with no shell. Its environment is `exec_host.env`, then the pairs of `-env`, then `TERM=xterm-256color` when no entry sets `TERM`.}
        returns {The name of the channel.}
        see {{ztcl::pty status} close exec}
        argument PROGRAM {
            type {program name or path}
            summary {The program to run.}
        }
        argument ARG {
            type string
            optional
            repeats
            summary {An argument of the program.}
        }
        example {
            set t [ztcl::pty spawn $sh]
            set r [fconfigure $t -translation]
            close $t
            set r
        } {binary binary}
        example {
            set t [ztcl::pty spawn -- $sh]
            set r [ztcl::pty status $t]
            close $t
            set r
        } running
        error {ztcl::pty spawn nosuchprogram_zz} {couldn't execute "nosuchprogram_zz": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {ztcl::pty spawn -bogus 1 x} {bad option "-bogus": must be -cwd, -env, or -size} NONE
        error {ztcl::pty spawn} {wrong # args: should be "ztcl::pty spawn ?-size {cols rows}? ?-cwd dir? ?-env list? program ?arg ...?"} {TCL WRONGARGS}
        option -size {
            value {{COLS ROWS}}
            type {list of two integers}
            default {80 24}
            summary {Gives the size of the terminal.}
            description {The count of columns and of rows, each 1 to 10,000 on Linux and macOS, and 1 to 32,767 on Windows. On macOS `spawn` sets the size on the other side of the terminal, since macOS gives EIO to a size on the master side before the other side has an open.}
            example {
                set t [ztcl::pty spawn -size {100 30} $sh]
                set r [ztcl::pty size $t]
                close $t
                set r
            } {100 30}
            error {ztcl::pty spawn -size 5 x} {bad size "5": must be {cols rows}} NONE
            error {ztcl::pty spawn -size {a b} x} {expected integer but got "a"} NONE
            error {ztcl::pty spawn -size} {value for "-size" missing} NONE
        }
        option -cwd {
            value DIR
            type path
            default {the current folder of file}
            summary {Gives the working folder of the program.}
            description {A folder of `file`, so it needs the capability `file`. The check is of the file system of the interpreter, so in host mode `-cwd` also works with no capability `file` ([issue 729](https://github.com/beetlebugorg/ztcl/issues/729)).}
            example {
                set t [ztcl::pty spawn -cwd . $sh]
                puts -nonewline $t "exit 0\r"
                set s [finish $t]
                close $t
                set s
            } {exit 0}
            error {ztcl::pty spawn -cwd nosuchdir $sh} {couldn't open the working folder: no such file or directory} {POSIX ENOENT {no such file or directory}}
        }
        option -env {
            value {{NAME VALUE ...}}
            type {list of names and values}
            summary {Adds variables to the environment of the program.}
            description {Pairs added to the environment of `exec_host.env`.}
            example {
                set t [ztcl::pty spawn -env {CODE 5} $sh]
                puts -nonewline $t [expr {$sh eq "cmd.exe" ? "exit %CODE%\r" : "exit \$CODE\r"}]
                set s [finish $t]
                close $t
                set s
            } {exit 5}
            error {ztcl::pty spawn -env x x} {-env needs a list of names and values} NONE
            error {ztcl::pty spawn -env {= 1} x} {bad environment name "="} NONE
        }
        option -- {
            type flag
            summary {Ends the options.}
            description {The next argument is PROGRAM, also when it starts with `-`.}
            example {
                set t [ztcl::pty spawn -- $sh]
                close $t
                string match pty* $t
            } 1
            noerrors {A flag has no value to check.}
        }
    }

    subcommand resize {
        synopsis {ztcl::pty resize CHANNEL COLS ROWS}
        summary {Sets the size of the terminal.}
        description {Sets the size of the terminal, and the program gets the change: SIGWINCH on Linux and macOS, and the console event on Windows. The limits are those of `-size`.}
        returns {An empty string.}
        see {{ztcl::pty size} {ztcl::vt resize}}
        argument CHANNEL {
            type channel
            summary {A channel of `spawn`.}
        }
        argument COLS {
            type integer
            summary {The count of columns.}
        }
        argument ROWS {
            type integer
            summary {The count of rows.}
        }
        example {
            set t [ztcl::pty spawn $sh]
            ztcl::pty resize $t 120 40
            set r [ztcl::pty size $t]
            close $t
            set r
        } {120 40}
        error {ztcl::pty resize stdout 1 1} {channel "stdout" is not a pty} NONE
        error {
            set t [ztcl::pty spawn $sh]
            catch {ztcl::pty resize $t a 5} m o
            close $t
            return -options $o $m
        } {expected integer but got "a"} NONE
        error {ztcl::pty resize stdout} {wrong # args: should be "ztcl::pty resize channel cols rows"} {TCL WRONGARGS}
    }

    subcommand size {
        synopsis {ztcl::pty size CHANNEL}
        summary {Gives the size of the terminal.}
        description {Gives the list `COLS ROWS`: the size of the terminal from the kernel on Linux and macOS, and the last size of `spawn` or `resize` on Windows.}
        returns {A list of two integers.}
        see {{ztcl::pty resize}}
        argument CHANNEL {
            type channel
            summary {A channel of `spawn`.}
        }
        example {
            set t [ztcl::pty spawn $sh]
            set r [ztcl::pty size $t]
            close $t
            set r
        } {80 24}
        error {ztcl::pty size stdout} {channel "stdout" is not a pty} NONE
        error {ztcl::pty size nochan} {can not find channel named "nochan"} {TCL LOOKUP CHANNEL nochan}
        error {ztcl::pty size} {wrong # args: should be "ztcl::pty size channel"} {TCL WRONGARGS}
    }

    subcommand status {
        synopsis {ztcl::pty status CHANNEL}
        summary {Gives whether the program runs, or how it ended.}
        description {Gives `running`, `{exit CODE}`, or `{signal NAME}`, such as `{signal KILL}`, with no wait. The status stays until `close`, and `close` ends the program and does not report its exit code as an error, since a terminal program often ends with a code other than 0.}
        returns {running, a list of exit and a code, or a list of signal and a name.}
        see {{ztcl::pty kill} close}
        argument CHANNEL {
            type channel
            summary {A channel of `spawn`.}
        }
        example {
            set t [ztcl::pty spawn $sh]
            set a [ztcl::pty status $t]
            puts -nonewline $t "exit 3\r"
            set b [finish $t]
            close $t
            list $a $b
        } {running {exit 3}}
        error {ztcl::pty status stdout} {channel "stdout" is not a pty} NONE
        error {ztcl::pty status} {wrong # args: should be "ztcl::pty status channel"} {TCL WRONGARGS}
    }

    subcommand kill {
        synopsis {ztcl::pty kill CHANNEL ?SIGNAL?}
        summary {Sends a signal to the program.}
        description {Sends SIGNAL to the program: `HUP` by default, `INT`, `QUIT`, `KILL`, `TERM`, `CONT`, `STOP`, `WINCH`, the same names with `SIG` in front, or a number from 1 to 64. On Linux and macOS the signal goes to the process group, and a number is the number of the system, so STOP and CONT differ: 19 and 18 on Linux, 17 and 19 on macOS. On Windows `INT` writes Ctrl-C (byte 3) to the input, `CONT`, `STOP`, and `WINCH` have no effect, each other signal ends the Job Object, and the numbers are 1, 2, 3, 9, and 15.}
        returns {An empty string.}
        see {{ztcl::pty status} close}
        argument CHANNEL {
            type channel
            summary {A channel of `spawn`.}
        }
        argument SIGNAL {
            type {signal name or number}
            optional
            summary {The signal to send.}
        }
        example {
            set t [ztcl::pty spawn $sh]
            ztcl::pty kill $t KILL
            set s [finish $t]
            close $t
            set s
        } {signal KILL}
        error {
            set t [ztcl::pty spawn $sh]
            catch {ztcl::pty kill $t BOGUS} m o
            close $t
            return -options $o $m
        } {bad signal "BOGUS": must be HUP, INT, QUIT, KILL, TERM, CONT, STOP, WINCH, or a number} NONE
        error {
            set t [ztcl::pty spawn $sh]
            catch {ztcl::pty kill $t 99} m o
            close $t
            return -options $o $m
        } {bad signal "99": must be HUP, INT, QUIT, KILL, TERM, CONT, STOP, WINCH, or a number} NONE
        error {ztcl::pty kill stdout} {channel "stdout" is not a pty} NONE
        error {ztcl::pty kill} {wrong # args: should be "ztcl::pty kill channel ?signal?"} {TCL WRONGARGS}
    }
}
