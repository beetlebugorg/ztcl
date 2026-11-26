# Errors

An error in Tcl stops the script and goes up through each caller, until a `catch` or a `try` stops it. An error has a message and an error code: a list that code can match. This lesson makes `add` check its input.

<!-- checkpoint -->
```tcl
set notes {}
```

## Give an error

The box gives `add` two checks. Each error has a code that starts with `JOT`, so that a caller can tell the errors of `jot` from other errors.

<!-- define -->
```tcl
proc add {text} {
    global notes
    if {[string trim $text] eq ""} {
        return -code error -errorcode {JOT EMPTY} "a note needs text"
    }
    if {[string length $text] > 80} {
        throw {JOT LONG} "a note has 80 characters at most"
    }
    lappend notes [dict create text $text done 0]
    return [llength $notes]
}
```

[`add "buy milk"`](run: "1") works. [`add ""`](run: "error: a note needs text") stops with the message. `error MESSAGE` gives an error with the code `NONE`. `throw CODE MESSAGE` and `return -code error -errorcode CODE` set a code.

## Stop an error with try

`try` runs a body and matches the result. `trap` matches the start of the error code, `on error` matches each error, and `on ok` matches a result. `finally` runs at the end in each case.

- [`try {add ""} trap {JOT EMPTY} {msg} {set r "empty: $msg"}`](run: "empty: a note needs text") matches one error.
- [`try {add [string repeat x 90]} trap {JOT} {msg opts} {dict get $opts -errorcode}`](run: "JOT LONG") matches each error of `jot`, and reads the code from the options.
- [`try {expr {1/0}} on error {msg opts} {dict get $opts -errorcode}`](run: "ARITH DIVZERO {divide by zero}") shows the code of an error of Tcl.

`catch` is the older form. [`catch {add ""} msg`](run: "1") gives 1 for an error and puts the message in `msg`. The variable `errorInfo` has the message and the stack of the last error. Run [`set errorInfo`](run:) to see the stack, and [`lindex [split $errorInfo \n] 0`](run: "a note needs text") to get its first line.

## A catch that hides each error

`catch {...}` with no check of its result hides each error: a typo, a missing variable, and a full disk look the same. [`proc save {} { catch {add ""}; return ok }`](run: "") and [`save`](run: "ok") give `ok` for a failure.

## Reading code an agent wrote

- Each `catch` checks its result, or the code has a comment that says why the error does not matter.
- `try` with `trap` matches one error code. `on error` matches each error, and is right only at the top of a program or around a whole job.
- An error that a caller can handle has an error code, and the message says what to change.
- `return -code error` in a proc points the error at the caller, and `error` points it at the line in the proc.

## Ask an agent

> Make `add` give an error with the code `JOT EMPTY` for empty text. In the caller, use `try` with `trap {JOT EMPTY}`, and let each other error go up.

## Try this

- Add a check to `add` for a note that is already in `notes`, with the code `JOT DUP`.
- Run `try {add ""} on ok {r} {set r} on error {m} {set m}`.
- Read `set errorCode` after an error of `add`.
