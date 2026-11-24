# The helper of the thread tests. tools/thread-tests.sh runs it before
# each test file in the same interpreter.
#
# `test name script want` runs the script at the global level. An error
# gives its message with a "!" in front. `testglob` compares with a
# pattern of `string match`. `done` writes the counts.
# SPDX-License-Identifier: BSD-2-Clause
set ::pass 0
set ::fail 0
proc result {script} {
    if {[catch {uplevel #0 $script} got]} {return "!$got"}
    return $got
}
proc test {name script want} {
    set got [result $script]
    if {$got eq $want} {incr ::pass; return}
    incr ::fail
    puts "FAIL $name\n  got:  $got\n  want: $want"
}
proc testglob {name script pattern} {
    set got [result $script]
    if {[string match $pattern $got]} {incr ::pass; return}
    incr ::fail
    puts "FAIL $name\n  got:  $got\n  want: $pattern"
}
# Waits until the script gives true, at most `ms` milliseconds.
proc waitfor {script {ms 5000}} {
    set end [expr {$ms / 10}]
    for {set i 0} {$i < $end} {incr i} {
        if {[uplevel #0 $script]} {return 1}
        after 10
    }
    return 0
}
proc done {} {
    puts "pass $::pass fail $::fail"
}
