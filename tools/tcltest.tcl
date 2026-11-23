# SPDX-License-Identifier: BSD-2-Clause
# A small stand-in for the tcltest package, for the test files of Tcl.
#
# Run it before a test file:
#   ztcl --keep-going tools/tcltest.tcl path/to/tcl/tests/set.test
#
# It has `test` (both forms), `testConstraint`, and `cleanupTests`,
# which prints the counts. A test with an unknown constraint, a regexp
# match, or an -output check counts as skipped.

set tt_pass 0
set tt_fail 0
set tt_skip 0
if {![info exists tt_verbose]} { set tt_verbose 0 }
array set tt_cons {
    unix 1 unixOnly 1 notRoot 1 tcl 1 wideIs64bit 1 longIs64bit 1
    ieeeFloatingPoint 1 eformat 1 emptyTest 0 knownBug 0 nonPortable 0
    userInteraction 0 win 0 winOnly 0 mac 0 longIs32bit 0 wideIs32bit 0
    bug-1773040 0 testevalex 0 testobj 0 testexprlong 0 testexprstring 0
}

proc tcltest::testConstraint {name args} {
    global tt_cons
    if {[llength $args] > 0} {
        set tt_cons($name) [lindex $args 0]
    }
    if {[info exists tt_cons($name)]} { return $tt_cons($name) }
    return 0
}

# The truth of one constraint word: a name, or "!name".
proc tt_allowed {c} {
    global tt_cons
    set want 1
    if {[string index $c 0] eq "!"} {
        set want 0
        set c [string range $c 1 end]
    }
    if {![info exists tt_cons($c)]} { return 0 }
    if {$tt_cons($c)} { return $want }
    return [expr {!$want}]
}

proc tcltest::test {name desc args} {
    global tt_pass tt_fail tt_skip tt_verbose
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
                -output - -errorOutput { incr tt_skip; return }
                default {}
            }
        }
    } elseif {[llength $args] == 3} {
        lassign $args constraints body result
    } else {
        lassign $args body result
    }
    foreach c $constraints {
        if {![tt_allowed $c]} { incr tt_skip; return }
    }
    if {$match ne "exact" && $match ne "glob"} { incr tt_skip; return }
    if {[catch {uplevel 1 $setup} msg]} {
        incr tt_fail
        if {$tt_verbose} { puts "FAIL $name: setup: $msg" }
        return
    }
    set code [catch {uplevel 1 $body} actual]
    catch {uplevel 1 $cleanup}
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
    if {$match eq "exact"} {
        set same [string equal $actual $result]
    } else {
        set same [string match $result $actual]
    }
    if {$code_ok && $same} {
        incr tt_pass
    } else {
        incr tt_fail
        if {$tt_verbose} {
            puts "FAIL $name: code $code"
            puts "  got:  $actual"
            puts "  want: $result"
        }
    }
}

proc tcltest::cleanupTests {args} {
    global tt_pass tt_fail tt_skip
    puts "pass $tt_pass fail $tt_fail skip $tt_skip"
}
proc tcltest::loadTestedCommands {args} {}
proc tcltest::configure {args} {}
proc tcltest::verbose {args} {}

# `interp alias {} name {} target ?arg ...?` makes a proc that calls
# the target. Other subcommands of `interp` are errors.
proc interp {sub args} {
    if {$sub ne "alias" || [llength $args] < 4} {
        error "interp $sub is not supported"
    }
    set target [lrange $args 3 end]
    proc [lindex $args 1] args "return \[uplevel 1 \[list $target {*}\$args\]\]"
    return [lindex $args 1]
}

# The commands that test files call around the tests.
proc package {args} { return 8.6 }
set tcl_library /usr/lib/tcl8.6
# The test commands are in the namespace tcltest, as in Tcl. A test
# file imports them.
namespace eval tcltest {namespace export *}
namespace import ::tcltest::*
