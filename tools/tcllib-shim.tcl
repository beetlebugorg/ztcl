# The commands of the tcllib test harness (devtools/testutilities.tcl)
# for tools/tcllib-tests.sh. Each package comes from the built-in modules
# of ztcl, so a test file runs against the native code.
# SPDX-License-Identifier: BSD-2-Clause

set tt_verbose 1
rename source ::tt_source
proc source {args} {
    # The file of the harness is this script.
    if {[string match *testutilities.tcl [lindex $args end]]} return
    uplevel 1 [list ::tt_source {*}$args]
}
proc testsNeedTcl {args} {}
proc testsNeedTcltest {args} {}
proc support {script} { uplevel #0 $script }
proc testing {script} { uplevel #0 $script }
proc useLocalFile {name} { uplevel #0 [list source $name] }
proc useLocal {file pkg args} { package require $pkg }
proc useAccel {accel path pkg} { package require $pkg }
proc useTcllibC {} { return 0 }
proc TestAccelInit {pkg} {}
proc TestAccelDo {pkg var body} {
    uplevel #0 [list set $var tcl]
    uplevel #0 $body
}
# The data files are next to the script that asks for them.
proc TestFilesGlob {pattern} {
    lsort [glob -nocomplain [file join [file dirname [info script]] $pattern]]
}
proc localPath {name} { return $name }
proc testsuiteCleanup {} {}
proc tcltest::wrongNumArgs {name args n} {
    return "wrong # args: should be \"$name $args\""
}
proc tcltest::tooManyArgs {name args} {
    return "wrong # args: should be \"$name $args\""
}

# lsort of ztcl takes no prefix of an option. json.testsuite uses -dict.
rename lsort ::tt_lsort
proc lsort {args} {
    set i [lsearch -exact $args -dict]
    if {$i >= 0} { lset args $i -dictionary }
    uplevel 1 [list ::tt_lsort {*}$args]
}
