# The command reference: ztcl::notify. The format is in
# docs/dev/reference-format.md.

command ztcl::notify {
    area ztcl
    since 1.0.0-beta.1
    capability notify
    flags {--allow notify}
    synopsis {ztcl::notify TITLE ?-subtitle TEXT? ?-body TEXT?}
    summary {Shows a notification of the system.}
    description {
        Shows one notification of the system, with a title and an optional subtitle and body, and gives an empty string. The options can come in any order, a later option replaces an earlier one with the same name, and an option has no short form.

        The command is not a package: it exists when the embedder turns on the capability `notify`, and a child interp has it only when its parent has it. The command checks each text first: the title has 1 to 256 bytes of UTF-8, the subtitle 0 to 256, and the body 0 to 4,096, and no text can have a NUL byte.

        The notifier is `Interp.notify_host` of the embedder when it has one, which gets each notification and gives false on a failure, else the notifier of the system. On macOS it is `/usr/bin/osascript` with `display notification`, and the texts go to a fixed script as its arguments, so no text becomes AppleScript code. On Windows it is a toast of the notification center through WinRT, under the name `ztcl`: the first notification writes the key `HKCU\Software\Classes\AppUserModelId\ztcl.ztcl`. Linux has no notifier in this version, and with no host the command gives `ZTCL NOTIFY UNAVAILABLE`. A failure of the notifier gives `ZTCL NOTIFY FAILED`.

        A notification shows text of the script outside the windows of the program, and can look like one of another app, so an embedder gives `notify` only to a script that it trusts with that. The command does not limit how often it shows a notification.

        The examples of this page run with `--allow notify`, and each one is an error of the checks, so no notification shows.
    }
    returns {An empty string.}
    page modules/notify/
    see {ztcl::open}
    argument TITLE {
        type string
        summary {The title, 1 to 256 bytes.}
    }
    example {
        catch {ztcl::notify ""} msg opts
        list $msg [dict get $opts -errorcode]
    } {{a notification needs a title} {ZTCL NOTIFY TEXT}}
    example {
        catch {ztcl::notify [string repeat é 129]} msg
        set msg
    } {the title of a notification has more than 256 bytes}
    error {ztcl::notify [string repeat a 257]} {the title of a notification has more than 256 bytes} {ZTCL NOTIFY LENGTH}
    error {ztcl::notify "a\x00b"} {the title of a notification has a NUL byte} {ZTCL NOTIFY TEXT}
    error {ztcl::notify a -icon x} {bad option "-icon": must be -body or -subtitle} NONE
    error {ztcl::notify a -sub x} {bad option "-sub": must be -body or -subtitle} NONE
    error {ztcl::notify a -body} {wrong # args: should be "ztcl::notify title ?-subtitle text? ?-body text?"} {TCL WRONGARGS}
    error {ztcl::notify} {wrong # args: should be "ztcl::notify title ?-subtitle text? ?-body text?"} {TCL WRONGARGS}
    option -subtitle {
        value TEXT
        type string
        default {an empty string}
        summary {Gives the subtitle, 0 to 256 bytes.}
        description {The line under the title. On Windows it is the second text of the toast.}
        example {
            catch {ztcl::notify a -subtitle [string repeat a 257]} msg
            set msg
        } {the subtitle of a notification has more than 256 bytes}
        error {ztcl::notify a -subtitle "x\x00"} {the subtitle of a notification has a NUL byte} {ZTCL NOTIFY TEXT}
    }
    option -body {
        value TEXT
        type string
        default {an empty string}
        summary {Gives the body, 0 to 4,096 bytes.}
        description {The text of the notification under the title and the subtitle.}
        example {
            catch {ztcl::notify "" -body x} msg
            set msg
        } {a notification needs a title}
        error {ztcl::notify a -body [string repeat a 4097]} {the body of a notification has more than 4096 bytes} {ZTCL NOTIFY LENGTH}
        error {ztcl::notify a -body "x\x00"} {the body of a notification has a NUL byte} {ZTCL NOTIFY TEXT}
    }
}
