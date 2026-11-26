# Module ztcl::open

`ztcl::open` opens a URL or a file in the default app of the system: a web page in the browser, a `mailto:` link in the mail app, or a document in the app that opens its type.

> [!NOTE]
> `ztcl::open` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
ztcl::open https://www.tcl-lang.org/
ztcl::open mailto:team@example.com
ztcl::open report.pdf
```

```sh
ztcl --allow launch,file report.tcl
```

## Synopsis

```tcl
ztcl::open URL-OR-PATH
```

Opens the target and gives an empty string. The command returns once the system accepts the target: on Windows when the shell started its action, on macOS when `/usr/bin/open` ended. It does not wait for the app.

A word whose first part is a scheme (a letter, then letters, digits, `+`, `-`, or `.`, then `:`, with two characters or more before the colon) is a URL. Another word is a path, so `C:/a.txt` is a path.

## Capability

| What | Capability | Runner |
|---|---|---|
| A URL | `launch` | `--allow launch` |
| A file | `launch` and `file` | `--allow launch,file` |

The command does not exist without `launch`. A file needs `file` because its path goes through the file commands: in host mode it is a path of the host, and with `--root DIR` it is a path in the root folder, and `..` and links cannot leave the root.

An embedder can give `Interp.launch_host`, a function that gets each target (the URL, or the full host path of a file) in place of the system, and gives false for a failure. The checks of this page run before it, so it gets only the targets that pass them.

The browser cannot start an app, so the commands of this helper do not run in the page. The helper shows how `ztcl::open` reads a target: a URL or a path, the capabilities that it needs, and the refusal of a scheme other than `http`, `https`, and `mailto`.

<!-- helper: ztcl::open -->
```tcl
# shell: none
# height: 155
helper::form
helper::row Target [ttk::entry .f.t -textvariable target -font TkFixedFont]
helper::footer 3 0
set target https://example.com/docs
proc build {} {
    set helper::cmd [list ztcl::open $::target]
    if {[regexp {^([A-Za-z][A-Za-z0-9+.-]+):} $::target -> scheme]} {
        if {[string tolower $scheme] ni {http https mailto}} {
            helper::result 0 "ZTCL OPEN SCHEME: ztcl::open does not open URLs with the scheme \"$scheme\""
        } else {
            helper::result 1 "A URL with the scheme $scheme. It needs launch:\nztcl --allow launch script.tcl"
        }
    } else {
        helper::result 1 "A path. It needs launch and file, and the type of the file must not be one that the system runs as code:\nztcl --allow launch,file script.tcl"
    }
}
helper::watch build target
```

## Platforms

| System | How | Refused files |
|---|---|---|
| Windows | `ShellExecuteExW` with the verb `open`, with no dialog of the shell | the types that Windows runs as code (below), and a named stream (`a.txt:s`) |
| macOS | `/usr/bin/open`, the program of LaunchServices, and its exit status | the types that macOS runs as code (below), with app bundles such as `.app`, and each regular file with an execute bit; a folder opens in Finder |
| Linux | none yet | the command gives `ZTCL OPEN UNAVAILABLE` unless `launch_host` is set |
| WebAssembly | none | the same error |

For a file, the command opens it and asks the system for the path of that open file (`GetFinalPathNameByHandleW` on Windows, `F_GETPATH` on macOS), and gives the app that path. So the app gets the file that the checks saw, also when a link pointed elsewhere.

The refused types of Windows: `exe`, `com`, `bat`, `cmd`, `scr`, `pif`, `lnk`, `url`, `msi`, `msp`, `mst`, `msc`, `cpl`, `hta`, `js`, `jse`, `vbs`, `vbe`, `vb`, `wsf`, `wsh`, `ws`, `wsc`, `sct`, `ps1`, `psm1`, `psd1`, `ps1xml`, `psc1`, `reg`, `inf`, `jar`, `appref-ms`, `application`, `gadget`, `scf`, `settingcontent-ms`, `chm`, `appx`, `appxbundle`, `msix`, `msixbundle`, `library-ms`, `search-ms`, `searchconnector-ms`, `diagcab`, `xll`, `xbap`, `website`, `shb`, `shs`, `job`, `mof`, `dll`, `ocx`, `sys`, `drv`, `cab`, `py`, `pyw`, `pl`, `rb`, `theme`, `themepack`, `deskthemepack`, `iso`, `img`, `vhd`, and `vhdx`.

The refused types of macOS: `app`, `command`, `tool`, `terminal`, `workflow`, `action`, `pkg`, `mpkg`, `scpt`, `scptd`, `applescript`, `jar`, `webloc`, `inetloc`, `fileloc`, `prefpane`, `kext`, `plugin`, `bundle`, `framework`, `sh`, `zsh`, `bash`, `csh`, `py`, `pl`, `rb`, `osax`, `saver`, `mobileconfig`, `dylib`, and `xpc`.

## Examples

A URL, with the capability `launch`:

```tcl
ztcl::open https://www.tcl-lang.org/man/tcl8.6/
```

A file that the script wrote, with `launch` and `file`:

```tcl
set f [open summary.html w]
puts $f "<h1>Done</h1>"
close $f
ztcl::open summary.html
```

The refusals, which give an error before any app starts:

```tcl
foreach target {file:///etc/hosts javascript:alert(1)} {
    catch {ztcl::open $target} msg opts
    puts "[dict get $opts -errorcode]: $msg"
}
;# ZTCL OPEN SCHEME: ztcl::open does not open URLs with the scheme "file"
;# ZTCL OPEN SCHEME: ztcl::open does not open URLs with the scheme "javascript"
```

On Windows:

```tcl
catch {ztcl::open C:/Windows/notepad.exe} msg opts
puts $msg    ;# ztcl::open does not open the file "C:/Windows/notepad.exe": the system runs it as a program
```

## Errors

| Error text | `-errorcode` |
|---|---|
| `ztcl::open does not open URLs with the scheme "S"` | `ZTCL OPEN SCHEME` |
| `a URL with a control character` | `ZTCL OPEN URL` |
| `ztcl::open of a file needs the file capability` | `ZTCL OPEN NOFILE` |
| `ztcl::open does not open the file "P": the system runs it as a program` | `ZTCL OPEN BLOCKED` |
| `ztcl::open does not open the file "P"` (a named stream on Windows) | `ZTCL OPEN BLOCKED` |
| `ztcl::open has no host path for "P"` | `ZTCL OPEN PATH` |
| `couldn't open "P": no such file or directory` | `POSIX ENOENT {no such file or directory}` |
| `couldn't access "P": permission denied` (a path out of the root folder) | `POSIX EACCES {permission denied}` |
| `could not open "T" in its default app` | `ZTCL OPEN FAILED` |
| `ztcl::open is not available on Linux yet` (and other systems) | `ZTCL OPEN UNAVAILABLE` |
| `wrong # args: should be "ztcl::open url-or-path"` | `TCL WRONGARGS` |

## Cost

Each call is one compute unit. The app runs outside the interpreter, so its work counts against no limit.

## Security

- **The app is not sandboxed.** It runs with the power of the user, outside the root folder and each limit of the interpreter. Grant `launch` only to scripts that you trust to open things for the user.
- Only `http`, `https`, and `mailto` URLs open. `file:`, `javascript:`, the schemes of other apps, and the custom schemes of protocol handlers are refused, because a scheme can start any app that registered it.
- A file that the system runs as a program is refused, so a script cannot start a program through its file type. The lists are deny lists, as the attachment rules of mail clients are: a new executable type of a later system version is not on them until a release adds it.
- The checks see the final path of the open file, so a link or `..` cannot point the app at another file after the check.
- With `--root DIR`, a file must be in the root folder.
