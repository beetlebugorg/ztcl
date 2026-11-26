# Module ztcl::notify

`ztcl::notify` shows a notification of the system: a title, and an optional subtitle and body.

```tcl
ztcl::notify "Build done" -subtitle ztcl -body "All 312 tests pass."
```

The command is not a package: it exists when the embedder turns on the capability `notify`, and it is absent otherwise. A child interp has it only when its parent has it.

## Command

```tcl
ztcl::notify TITLE ?-subtitle TEXT? ?-body TEXT?
```

Shows one notification and gives an empty string. The options can come in any order, and a later option replaces an earlier one with the same name.

| Text | Limit |
|---|---|
| `TITLE` | 1 to 256 bytes of UTF-8 |
| `-subtitle` | 0 to 256 bytes of UTF-8 |
| `-body` | 0 to 4,096 bytes of UTF-8 |

No text can have a NUL byte.

## The notifier

The notifier is the first of these that exists:

1. `Interp.notify_host` of the embedder. It gets each notification (`notify.Note`: the title, the subtitle, and the body) and gives false on a failure. An app in a macOS app bundle shows it with `UNUserNotificationCenter`, and the tests record the calls.
2. The system notifier of the platform.

| Platform | System notifier |
|---|---|
| macOS | `/usr/bin/osascript` with `display notification`. The notification shows under the name of Script Editor. A program in an app bundle uses `notify_host` to show it under the name of the app. |
| Windows | None in this version. With no host, the command gives `ZTCL NOTIFY UNAVAILABLE`. |
| Linux | None in this version. With no host, the command gives `ZTCL NOTIFY UNAVAILABLE`. |
| WASI, the web | The command needs a host. |

On macOS the texts go to a fixed script as its arguments:

```applescript
on run argv
display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv)
end run
```

So no text of the caller is AppleScript code. The standard input, output, and error of `osascript` are `/dev/null`, and the command waits for its exit status.

## Errors

| `-errorcode` | Message |
|---|---|
| `TCL WRONGARGS` | `wrong # args: should be "ztcl::notify title ?-subtitle text? ?-body text?"` |
| `NONE` | `bad option "-icon": must be -body or -subtitle` |
| `ZTCL NOTIFY TEXT` | `a notification needs a title` |
| `ZTCL NOTIFY TEXT` | `the body of a notification has a NUL byte` (and for the title and the subtitle) |
| `ZTCL NOTIFY TEXT` | `the title of a notification is not UTF-8` (and for the subtitle and the body) |
| `ZTCL NOTIFY LENGTH` | `the title of a notification has more than 256 bytes`, and `... more than 4096 bytes` for the body |
| `ZTCL NOTIFY FAILED` | `the system did not show the notification`: the host gave false, or `osascript` ended with a status other than 0 |
| `ZTCL NOTIFY UNAVAILABLE` | `ztcl::notify is not available on Linux yet` (or Windows): no host, and no system notifier |

```tcl
if {[catch {ztcl::notify Done -body "Saved."} msg]} {
    puts "no notification: $msg ($::errorCode)"
}
```

## Security

- The capability shows text of the script in the user interface of the system, outside the windows of the program. A script can show a notification that looks like one of another app, so give `notify` only to a script that you trust with that.
- The texts never become code: `osascript` gets them as arguments of a fixed script.
- The command does not limit how often it shows a notification. The system can limit it, and an embedder can limit it in `notify_host`.
