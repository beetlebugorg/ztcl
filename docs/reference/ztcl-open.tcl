# The command reference: ztcl::open. The format is in
# docs/dev/reference-format.md.

command ztcl::open {
    area ztcl
    since 1.0.0-beta.1
    capability launch
    flags {--allow launch}
    synopsis {ztcl::open URL-OR-PATH}
    summary {Opens a URL or a file in the default app of the system.}
    description {
        Opens a web page in the browser, a `mailto:` link in the mail app, or a document in the app that opens its type, and gives an empty string. The command returns once the system accepts the target: on Windows when the shell started its action, and on macOS when `/usr/bin/open` ended. It does not wait for the app.

        A word whose first part is a scheme, a letter, then letters, digits, `+`, `-`, or `.`, then `:`, with two characters or more before the colon, is a URL. Another word is a path, so `C:/a.txt` is a path. Only `http`, `https`, and `mailto` URLs open, in any case of the letters: `file:`, `javascript:`, the schemes of other apps, and the custom schemes of protocol handlers give an error, since a scheme can start any app that registered it.

        The command exists only with the capability `launch`, and a file also needs `file`: its path goes through the file commands, so in host mode it is a path of the host, and with `--root DIR` it is a path in the root folder that `..` and links cannot leave. The command opens the file and gives the app the final path of that open file, so the app gets the file that the checks saw. A file that the system runs as a program gives an error: on Windows the types such as `exe`, `bat`, `lnk`, `ps1`, `msi`, and `py`, and a named stream such as `a.txt:s`; on macOS the types such as `app`, `command`, `pkg`, `sh`, and `py`, and each regular file with an execute bit. The module page has the full lists.

        Windows uses `ShellExecuteExW` with the verb `open`, and macOS `/usr/bin/open`. Linux and WebAssembly have no backend yet: the command gives `ZTCL OPEN UNAVAILABLE` there, unless the embedder gives `Interp.launch_host`, a function that gets each target that passes the checks in place of the system. The app runs outside the interpreter with the power of the user, and is not sandboxed. Each call is one compute unit.

        The examples of this page run with `--allow launch` only, and no example opens an app.
    }
    returns {An empty string.}
    page modules/open/
    see {exec open}
    argument URL-OR-PATH {
        type {URL or path}
        summary {An http, https, or mailto URL, or the path of a file.}
    }
    example {
        catch {ztcl::open file:///etc/hosts} msg opts
        list $msg [dict get $opts -errorcode]
    } {{ztcl::open does not open URLs with the scheme "file"} {ZTCL OPEN SCHEME}}
    example {
        catch {ztcl::open C:/a.txt} msg
        set msg
    } {ztcl::open of a file needs the file capability}
    example {info commands ztcl::open} ::ztcl::open
    error {ztcl::open javascript:alert(1)} {ztcl::open does not open URLs with the scheme "javascript"} {ZTCL OPEN SCHEME}
    error {ztcl::open FILE:x} {ztcl::open does not open URLs with the scheme "FILE"} {ZTCL OPEN SCHEME}
    error {ztcl::open "https://example.com/\x01"} {a URL with a control character} {ZTCL OPEN URL}
    error {ztcl::open "mailto:a\nb"} {a URL with a control character} {ZTCL OPEN URL}
    error {ztcl::open report.pdf} {ztcl::open of a file needs the file capability} {ZTCL OPEN NOFILE}
    error {ztcl::open} {wrong # args: should be "ztcl::open url-or-path"} {TCL WRONGARGS}
    error {ztcl::open a b} {wrong # args: should be "ztcl::open url-or-path"} {TCL WRONGARGS}
}
