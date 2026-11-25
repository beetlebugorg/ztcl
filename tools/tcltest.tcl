# SPDX-License-Identifier: BSD-2-Clause
# A small stand-in for the tcltest package, for the test files of Tcl.
#
# Run it before a test file, and run tools/tcltest-end.tcl after it:
#   ztcl --keep-going tools/tcltest.tcl path/to/tcl/tests/set.test \
#       tools/tcltest-end.tcl
#
# It has `test` (both forms), `testConstraint`, `customMatch`, and
# `cleanupTests`. It checks -output and -errorOutput. The check of the
# constraints follows the three forms of tcltest: a Tcl expression, an
# expression of names, and a list of names. A test that cannot run
# counts as skipped, with the reason in tt_why.

# The platform constraints have the values of tcltest 2.5.9 on Linux.
# Constraints for features that ztcl lacks (exec, files, memory) stay
# false, and those tests count as blocked.
set tt_pass 0
set tt_fail 0
set tt_skip 0
if {![info exists tt_verbose]} { set tt_verbose 0 }
proc tt_note {kind {why {}}} {
    global tt_pass tt_fail tt_skip tt_why
    switch -- $kind {
        pass { incr tt_pass }
        fail { incr tt_fail }
        default {
            incr tt_skip
            if {[info exists tt_why($why)]} { incr tt_why($why) } else { set tt_why($why) 1 }
        }
    }
}

# The commands that a child interpreter also gets.
set tt_script {
array set tt_cons {
    unix 1 unixOnly 1 notRoot 1 tcl 1 wideIs64bit 1 longIs64bit 1
    ieeeFloatingPoint 1 eformat 1 emptyTest 0 knownBug 0 nonPortable 0
    userInteraction 0 win 0 winOnly 0 mac 0 longIs32bit 0 wideIs32bit 0
    bug-1773040 0 testevalex 0 testobj 0 testexprlong 0 testexprstring 0
    unixOrPc 1 macOrPc 0 macOrUnix 1 unixOrWin 1 macOrWin 0 pc 0 nt 0 root 0
    tempNotPc 1 tempNotWin 1 tempNotMac 1 tempNotUnix 0
    unixCrash 0 winCrash 1 pcCrash 1 macCrash 1
}

# A constraint for a command is true only when ztcl has the command.
set tt_cons(socket) [llength [info commands socket]]

set tt_cons(exec) [llength [info commands exec]]
# The `tclsh` of the tests is the ztcl runner, through the script
# `ztclsh` of tools/suite.sh. `stdio` is true when a pipeline to it
# opens. `unixExecs` is true when the host has the programs that
# tcltest looks for.
proc tcltest::interpreter {args} { return /ztclsh }
set tt_cons(stdio) 0
set tt_cons(unixExecs) 0
if {$tt_cons(exec) && [llength [info commands file]] && [file exists /ztclsh]} {
    catch {
        set tt_f [open "|[list [tcltest::interpreter]]" w]
        puts $tt_f exit
        close $tt_f
        set tt_cons(stdio) 1
    }
    catch {
        foreach tt_p {cat echo sh wc sleep fgrep ps chmod mkdir} {
            exec sh -c "command -v $tt_p"
        }
        set tt_cons(unixExecs) 1
    }
}

proc tcltest::testConstraint {name args} {
    global tt_cons
    if {[llength $args] > 0} {
        set tt_cons($name) [lindex $args 0]
    }
    if {[info exists tt_cons($name)]} { return $tt_cons($name) }
    return 0
}

# The value of one named constraint. An unknown name is false.
proc tt_con {c} {
    global tt_cons
    return [expr {[info exists tt_cons($c)] && $tt_cons($c)}]
}

# Gives the first constraint that stops a test, or an empty string.
proc tt_blocked {constraints} {
    global tt_cons
    if {[string match {*[$\[]*} $constraints]} {
        if {[catch {uplevel #0 [list expr $constraints]} ok] || !$ok} {
            return "expr:$constraints"
        }
        return {}
    }
    if {[regexp {[^.:_a-zA-Z0-9 \n\r\t]} $constraints]} {
        regsub -all {[.\w]+} $constraints {[tt_con &]} e
        if {[catch {expr $e} ok] || !$ok} { return "expr:$constraints" }
        return {}
    }
    foreach c $constraints {
        if {![tt_con $c]} { return $c }
    }
    return {}
}

proc tt_skip {why} { tt_note skip $why }

# The match modes. `customMatch` adds a mode.
array set tt_match {exact {string equal} glob {string match} regexp {regexp --}}
proc tcltest::customMatch {mode script} {
    set ::tt_match($mode) $script
}
proc tt_same {mode want got} {
    global tt_match
    return [uplevel #0 $tt_match($mode) [list $want $got]]
}

# Takes the place of `puts` while a test checks its output.
rename puts tt_puts
set tt_capture 0
proc puts {args} {
    global tt_capture tt_out tt_err
    if {!$tt_capture} { return [tt_puts {*}$args] }
    set nl \n
    if {[lindex $args 0] eq "-nonewline"} {
        set nl {}
        set args [lrange $args 1 end]
    }
    switch [llength $args] {
        1 { set ch stdout; set text [lindex $args 0] }
        2 { lassign $args ch text }
        default { error {wrong # args: should be "puts ?-nonewline? ?channelId? string"} }
    }
    switch -- $ch {
        stdout { append tt_out $text $nl }
        stderr { append tt_err $text $nl }
        default { error "can not find channel named \"$ch\"" }
    }
    return
}

proc tcltest::test {name desc args} {
    global tt_verbose tt_match tt_capture tt_out tt_err
    set constraints {}
    set setup {}
    set cleanup {}
    set match exact
    set codes {ok return}
    set body {}
    set result {}
    if {[string index [lindex $args 0] 0] eq "-" && [llength $args] % 2 == 0} {
        foreach {k v} $args {
            switch -- $k {
                -constraints { set constraints $v }
                -setup { set setup $v }
                -body { set body $v }
                -cleanup { set cleanup $v }
                -result { set result $v }
                -returnCodes { set codes $v }
                -match { set match $v }
                -output { set want_out $v }
                -errorOutput { set want_err $v }
                default {}
            }
        }
    } elseif {[llength $args] == 3} {
        lassign $args constraints body result
    } else {
        lassign $args body result
    }
    set why [tt_blocked $constraints]
    if {$why ne ""} { tt_skip $why; return }
    if {![info exists tt_match($match)]} { tt_skip "match:$match"; return }
    if {$tt_verbose > 1} { puts "RUN $name" }
    set tt_out {}
    set tt_err {}
    set capture [expr {[info exists want_out] || [info exists want_err]}]
    set tt_capture $capture
    set setup_code [catch {uplevel 1 $setup} setup_msg]
    if {$setup_code == 1} {
        set tt_capture 0
        tt_note fail
        if {$tt_verbose} { puts "FAIL $name: setup: $setup_msg" }
        catch {uplevel 1 $cleanup}
        return
    }
    set code [catch {uplevel 1 $body} actual]
    set clean_code [catch {uplevel 1 $cleanup} clean_msg]
    set tt_capture 0
    set code_ok 0
    foreach c $codes {
        switch -- $c {
            ok { set c 0 }
            error { set c 1 }
            return { set c 2 }
            break { set c 3 }
            continue { set c 4 }
        }
        if {$c == $code} { set code_ok 1 }
    }
    if {[catch {tt_same $match $result $actual} same]} { set same 0 }
    set out_ok 1
    if {[info exists want_out] && [catch {tt_same $match $want_out $tt_out} out_ok]} {
        set out_ok 0
    }
    set err_ok 1
    if {[info exists want_err] && [catch {tt_same $match $want_err $tt_err} err_ok]} {
        set err_ok 0
    }
    if {$code_ok && $same && $out_ok && $err_ok && $clean_code != 1} {
        tt_note pass
    } else {
        tt_note fail
        if {$tt_verbose} {
            puts "FAIL $name: code $code"
            puts "  got:  $actual"
            puts "  want: $result"
            if {$clean_code == 1} { puts "  cleanup: $clean_msg" }
            if {!$out_ok} { puts "  output: $tt_out" }
            if {!$err_ok} { puts "  errorOutput: $tt_err" }
        }
    }
}

proc tcltest::cleanupTests {args} {
    if {[info exists ::tt_child]} return
    global tt_pass tt_fail tt_skip
    puts "pass $tt_pass fail $tt_fail skip $tt_skip"
}
proc tcltest::loadTestedCommands {args} {}
proc tcltest::configure {args} {}
proc tcltest::verbose {args} {}
# The debug output of a test file goes nowhere.
proc tcltest::DebugPuts {level string} {}
# The variables of tcltest that test files read.
set tcltest::verbose {body error}

}
eval $tt_script
# The stand-in `interp`, for a runner with no `interp` capability:
# `interp alias {} name {} target ?arg ...?` makes a proc that calls the
# target. Other subcommands are errors.
if {[llength [info commands interp]] == 0} {
    proc interp {sub args} {
        if {$sub ne "alias" || [llength $args] < 4} {
            error "interp $sub is not supported"
        }
        set target [lrange $args 3 end]
        proc [lindex $args 1] args "return \[uplevel 1 \[list $target {*}\$args\]\]"
        return [lindex $args 1]
    }
}

# The file helpers of tcltest, for a runner with the `file` capability.
# Each path is inside the root folder of the runner.
set tt_files {
    proc tcltest::temporaryDirectory {args} { return [pwd] }
    proc tcltest::testsDirectory {args} { return [pwd] }
    proc tcltest::workingDirectory {args} { return [pwd] }
    proc tcltest::makeFile {contents name {dir {}}} {
        if {$dir eq ""} { set dir [pwd] }
        set path [file join $dir $name]
        set f [open $path w]
        fconfigure $f -translation lf
        if {[string index $contents end] ne "\n"} { append contents \n }
        puts -nonewline $f $contents
        close $f
        return $path
    }
    proc tcltest::removeFile {name {dir {}}} {
        if {$dir eq ""} { set dir [pwd] }
        file delete -force [file join $dir $name]
        return
    }
    proc tcltest::makeDirectory {name {dir {}}} {
        if {$dir eq ""} { set dir [pwd] }
        set path [file join $dir $name]
        file mkdir $path
        return $path
    }
    proc tcltest::removeDirectory {name {dir {}}} {
        if {$dir eq ""} { set dir [pwd] }
        file delete -force [file join $dir $name]
        return
    }
    proc tcltest::viewFile {name {dir {}}} {
        if {$dir eq ""} { set dir [pwd] }
        set f [open [file join $dir $name]]
        set text [read -nonewline $f]
        close $f
        return $text
    }
}
if {[llength [info commands file]]} { eval $tt_files }

# The commands that test files call around the tests.
if {[llength [info commands package]] == 0} {
    proc package {args} { return 8.6 }
} else {
    package provide Tcl 8.6.16
    package provide tcltest 2.5.9
}
set tcl_library /usr/lib/tcl8.6
# The variables that tclsh sets for a script with no arguments.
set argv {}
set argc 0
set auto_path {}

# Loads the test commands into a child. Its counts go to this file.
proc tcltest::loadIntoChildInterpreter {child args} {
    interp eval $child [list set ::tt_child 1]
    interp eval $child [list set ::tt_verbose $::tt_verbose]
    interp eval $child {set ::auto_path {}; set ::argv {}; set ::argc 0}
    interp eval $child $::tt_script
    if {[interp eval $child {llength [info commands file]}]} { interp eval $child $::tt_files }
    interp alias $child tt_note {} tt_note
    interp eval $child {catch {package provide tcltest 2.5.9}; catch {package provide Tcl 8.6.16}}
    interp eval $child {namespace eval tcltest {namespace export *}; namespace import ::tcltest::*}
    return
}

# The test commands are in the namespace tcltest, as in Tcl. A test
# file imports them.
namespace eval tcltest {namespace export *}
namespace import ::tcltest::*
