# Write a package

A package is a namespace of commands with a name and a version, that other scripts load with `package require`. This lesson makes `jot` a package from start to end: the code, the index, tests, docs, versions, and the ways to give it to others. The ztcl part is a list of the capabilities of the package and the compute cost of its commands. The agent part makes the package easy for an agent to call correctly.

<!-- checkpoint -->
```tcl
```

## The code

A package has one namespace, with the name of the package. It exports the commands for its users, and ends with `package provide`.

<!-- file: jot/jot.tcl -->
```tcl
namespace eval jot {
    variable notes {}
    proc add {text} {
        variable notes
        if {[string trim $text] eq ""} {
            return -code error -errorcode {JOT EMPTY} "a note needs text"
        }
        lappend notes [dict create text $text done 0]
        return [llength $notes]
    }
    proc count {} {
        variable notes
        return [llength $notes]
    }
    namespace export add count
    namespace ensemble create
}
package provide jot 0.1.0
```

## The index

`pkgIndex.tcl` tells `package` how to load each version. The variable `dir` is the folder of the index.

<!-- file: jot/pkgIndex.tcl -->
```tcl
package ifneeded jot 0.1.0 [list source [file join $dir jot.tcl]]
```

tclsh finds each `pkgIndex.tcl` in the folders of `auto_path`. ztcl reads no folder by itself: the script or the host runs the index. With the capability `package` and `file`, a script loads the package so:

<!-- run: --allow package,file,channels -->
```tcl
set dir [file join [pwd] jot]
source [file join $dir pkgIndex.tcl]
puts [package require jot]
puts [jot add "buy milk"]
```

```text
0.1.0
1
```

## Versions

A version is numbers with dots. `package require jot 0.1` loads 0.1 or a later 0.x version, and `package require -exact jot 0.1.0` loads only that one. Change the first number for a change that breaks a caller, the second for a new command, and the third for a fix. `package vsatisfies 0.2.0 0.1` is true, and `package vsatisfies 1.0.0 0.1` is false.

## Tests

ztcl has no `tcltest` package in this version. A test is a script that runs the commands and compares the results, and it fails with an error. Keep the tests next to the package, and run them in CI:

<!-- file: jot/tests.tcl -->
```tcl
proc check {name script want} {
    set got [uplevel #0 $script]
    if {$got ne $want} { error "$name: got $got, want $want" }
    puts "ok $name"
}
source jot/jot.tcl
check add {jot add "buy milk"} 1
check count {jot count} 1
check empty {catch {jot add ""} m; set m} "a note needs text"
```

`ztcl --allow file,channels jot/tests.tcl` runs it from the folder above `jot`. Test each error too: the message and the error code are a part of the interface.

## Capabilities and compute cost

A package that uses `file`, `socket`, or `exec` needs that capability in each program that loads it. Write the list at the top of the docs, so that a user knows what to turn on before the first run. `jot` needs no capability: it keeps the notes in memory, and the caller saves them.

Give the compute cost of each command. `ztcl --report` prints the compute units of a run. `source` of `jot.tcl` used 13 compute units, and one `jot add` used 7 more, measured with `ztcl --allow file,channels,package --report` on the code above. A cost that grows with the data, such as a search of each note, is a number for each note.

## Give it to others

- A folder: `jot/` with `jot.tcl` and `pkgIndex.tcl`. A user sources the index, as above.
- A single file: `jot.tcl` with `package provide`. A user runs `source jot.tcl`.
- In a binary: `ztcl build --embed jot -o app main.tcl` puts the folder in the binary under `//zipfs:/app/jot/`. `main.tcl` sets `dir` to that folder and sources the index. [Build a program](../build.md) has the details.

## Make it easy for an agent

An agent calls a package correctly when its facts are in one place and the examples run. For `jot`:

- One docs page in the shape of a page of the command reference (issue [#238](https://github.com/beetlebugorg/ztcl/issues/238)): the synopsis of each command, its arguments, its result, its errors with their codes, its compute cost, and the capability it needs.
- Examples in the docs that CI runs, so that a wrong example fails the build.
- The capability list in one place, at the top of the docs and in a comment at the top of `jot.tcl`.
- Error codes that start with the name of the package, such as `JOT EMPTY`, so that a caller can `trap` them.

## Ask an agent

> Write a Tcl package `jot` 0.1.0: a namespace with an ensemble, `package provide`, a `pkgIndex.tcl`, and a test script with one check for each command and each error. List the capabilities that it needs at the top of `jot.tcl`.

## Try this

- Add `jot remove {i}` with the error code `JOT RANGE`, a test for it, and the version 0.2.0.
- Load the package with `package require jot 0.2`, and read the error with the version 0.1.0.
- Measure the compute units of 100 calls of `jot add` with `ztcl --report`.
