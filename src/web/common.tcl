# The helpers of the wrappers of the groups of web:: (#251). The host
# runs this script before the script of each granted group (src/wasm.zig
# ztcl_web_lib).
#
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::web::lib {}

# Runs the callback script of a user at the global level with `args`
# appended as list elements, as the bridge runs a script of -command.
proc ::web::lib::reply {script args} {
    if {$script eq ""} return
    uplevel #0 "$script [list {*}$args]"
}

# The callback of a call with no -command of the user: an error goes to
# the error handler of the page (onEvents of web/ztcl.mjs).
proc ::web::lib::fail {status value} {
    if {$status eq "error"} {error $value}
}

# Parses `-name value` pairs of `argv` by `spec`, a dict of the names
# (without the dash) and their default values. Gives a dict. `usage` is
# the text of the error for a bad call.
proc ::web::lib::options {usage spec argv} {
    if {[llength $argv] % 2} {
        return -code error "wrong # args: should be \"$usage\""
    }
    set out $spec
    foreach {k v} $argv {
        set n [string range $k 1 end]
        if {[string index $k 0] ne "-" || ![dict exists $spec $n]} {
            set names [lmap x [lsort [dict keys $spec]] {string cat - $x}]
            if {[llength $names] > 1} {
                set last [lindex $names end]
                set names "[join [lrange $names 0 end-1] {, }], or $last"
            }
            return -code error "bad option \"$k\": must be $names"
        }
        dict set out $n $v
    }
    return $out
}

# The handle of the root object `path`, or an error that names the API
# for a browser without it: "web::bluetooth: this browser has no Web
# Bluetooth".
proc ::web::lib::root {path ns api} {
    if {[catch {web::root $path} h]} {
        if {[string match "web: this browser has no *" $h]} {
            return -code error -errorcode [list WEB UNSUPPORTED $path] "$ns: this browser has no $api"
        }
        return -code error $h
    }
    return $h
}
