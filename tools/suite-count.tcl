# SPDX-License-Identifier: BSD-2-Clause
# Counts the tests that a Tcl test file defines, with a real tclsh.
#
#   tclsh tools/suite-count.tcl path/to/file.test
#
# The file runs in a safe interpreter, so it has no files, sockets, or
# processes. The `test` command counts each call and runs no test body.
# Each constraint is true, so the count includes the tests in a block
# that depends on a constraint. An error at the top level of the file
# stops that one command. Prints the file name and the count.

set path [lindex $argv 0]
set f [open $path]
fconfigure $f -encoding utf-8
set text [read $f]
close $f

set i [interp create -safe]
$i eval {
    set ::tt_count 0
    namespace eval ::tcltest {
        namespace export *
        variable testConstraints
        proc test {args} { incr ::tt_count; return }
        proc testConstraint {name args} { return 1 }
        proc cleanupTests {args} {}
        proc loadTestedCommands {args} {}
        proc configure {args} {}
        proc customMatch {args} {}
    }
    namespace import ::tcltest::*
    proc package {args} { return 8.6 }
    proc unknown {args} { return {} }
}
set cmd {}
foreach line [split $text \n] {
    append cmd $line \n
    if {![info complete $cmd]} continue
    # Each top-level command has its own limit, so one endless loop
    # stops only that command.
    $i limit command -value {}
    $i limit command -value [expr {[$i eval {info cmdcount}] + 5000000}]
    catch {$i eval $cmd}
    set cmd {}
}
$i limit command -value {}
puts "[file tail $path] [$i eval {set ::tt_count}]"
